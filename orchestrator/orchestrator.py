#!/usr/bin/env python3
"""
AjipSnD multi-account rotation orchestrator.

MT5 has no API to switch a running EA's own account, so the rotation
happens at the TERMINAL level instead: this script keeps ONE MT5 terminal
logged into ONE account at a time. The EA writes a handoff signal file to
Common\\Files (AjipSnD_Trade.mqh:WriteHandoffSignal) after EVERY trade
close (reason=TRADE_CLOSED), and also when its daily target/max-loss is
hit (reason=DAILY_TARGET/DAILY_MAX_LOSS). This script polls for that file,
waits until the account is flat, then calls mt5.login() to move to the
next account. Only the daily-target/max-loss reasons bench an account for
the rest of the day (see DAILY_LIMIT_REASONS) — a plain TRADE_CLOSED
handoff just advances to the next account in line, so the same account
comes back around once the rotation cycles through the rest.

Setup:
    pip install -r requirements.txt
    cp accounts.example.json accounts.json
    python orchestrator.py

accounts.json and state.json are gitignored — they hold live credentials.
"""

import csv
import datetime
import json
import os
import sys
import time

import MetaTrader5 as mt5

CONFIG_PATH = os.path.join(os.path.dirname(__file__), "accounts.json")
STATE_PATH = os.path.join(os.path.dirname(__file__), "state.json")
LIVE_STATUS_PATH = os.path.join(os.path.dirname(__file__), "live_status.json")
HANDOFF_HISTORY_PATH = os.path.join(os.path.dirname(__file__), "handoff_history.csv")

DEFAULT_POLL_INTERVAL_SECONDS = 5
DEFAULT_HANDOFF_FILENAME = "AjipSnD_Handoff.csv"
FLAT_WAIT_WARN_INTERVAL_SECONDS = 30

# Handoff reasons that mean "this account is actually done for the day" —
# only these bench the account until tomorrow. TRADE_CLOSED (fired after
# every individual trade, win or lose) just rotates to the next account in
# line without benching, so the same account is eligible again as soon as
# its turn comes back around, even later the same day.
DAILY_LIMIT_REASONS = {"DAILY_TARGET", "DAILY_MAX_LOSS"}

DEFAULT_HEARTBEAT_FILENAME = "AjipSnD_Heartbeat.csv"
DEFAULT_HEARTBEAT_GRACE_SECONDS = 60
DEFAULT_HEARTBEAT_TIMEOUT_SECONDS = 90
HEARTBEAT_WARN_REPEAT_SECONDS = 60

HANDOFF_HISTORY_HEADER = "handled_at,login,reason,pnl,symbol,magic,event_time,outcome,next_login\n"


def load_config(path):
    with open(path, "r") as f:
        cfg = json.load(f)

    accounts = cfg["accounts"]
    if not accounts:
        raise ValueError("accounts.json: 'accounts' list is empty")

    cfg.setdefault("poll_interval_seconds", DEFAULT_POLL_INTERVAL_SECONDS)
    cfg.setdefault("handoff_filename", DEFAULT_HANDOFF_FILENAME)
    cfg.setdefault("mt5_terminal_path", None)
    cfg.setdefault("heartbeat_filename", DEFAULT_HEARTBEAT_FILENAME)
    cfg.setdefault("heartbeat_grace_seconds", DEFAULT_HEARTBEAT_GRACE_SECONDS)
    cfg.setdefault("heartbeat_timeout_seconds", DEFAULT_HEARTBEAT_TIMEOUT_SECONDS)
    return cfg


def load_state():
    if not os.path.exists(STATE_PATH):
        return {"current_index": 0, "maxed_today": {}}
    with open(STATE_PATH, "r") as f:
        return json.load(f)


def save_state(state):
    with open(STATE_PATH, "w") as f:
        json.dump(state, f, indent=2)


def today_str():
    return datetime.date.today().isoformat()


def parse_kv_file(path):
    data = {}
    with open(path, "r") as f:
        for line in f:
            line = line.strip()
            if not line or "=" not in line:
                continue
            key, value = line.split("=", 1)
            data[key.strip()] = value.strip()
    return data


def common_files_dir():
    info = mt5.terminal_info()
    if info is None:
        raise RuntimeError(f"terminal_info() failed: {mt5.last_error()}")
    return os.path.join(info.commondata_path, "Files")


def terminal_files_dir():
    info = mt5.terminal_info()
    if info is None:
        raise RuntimeError(f"terminal_info() failed: {mt5.last_error()}")
    return os.path.join(info.data_path, "MQL5", "Files")


def mt5_login(account, terminal_path):
    login = int(account["login"])
    password = account["password"]
    server = account["server"]

    if not mt5.initialize(path=terminal_path):
        print(f"[orchestrator] mt5.initialize() failed: {mt5.last_error()}", flush=True)
        return False

    if not mt5.login(login, password=password, server=server):
        print(f"[orchestrator] LOGIN FAILED for {login}@{server}: {mt5.last_error()}", flush=True)
        return False

    info = mt5.account_info()
    print(f"[orchestrator] Logged in: {info.login}@{info.server} "
          f"balance={info.balance:.2f} equity={info.equity:.2f}", flush=True)
    return True


def write_live_status(accounts, state, ea_status):
    try:
        info = mt5.account_info()
        if info is None:
            return

        positions = mt5.positions_get() or []
        positions_payload = [
            {
                "symbol": p.symbol,
                "type": "BUY" if p.type == mt5.ORDER_TYPE_BUY else "SELL",
                "volume": p.volume,
                "profit": p.profit,
                "open_time": datetime.datetime.fromtimestamp(p.time).isoformat(),
            }
            for p in positions
        ]

        payload = {
            "updated_at": datetime.datetime.now().isoformat(),
            "files_dir": terminal_files_dir(),
            "current_login": info.login,
            "current_server": info.server,
            "balance": info.balance,
            "equity": info.equity,
            "floating_pnl": info.profit,
            "positions": positions_payload,
            "rotation_index": state["current_index"],
            "rotation_size": len(accounts),
            "ea_alive": ea_status["alive"],
            "ea_status_detail": ea_status["detail"],
            "ea_heartbeat_age_seconds": ea_status["age_seconds"],
        }
        tmp_path = LIVE_STATUS_PATH + ".tmp"
        with open(tmp_path, "w") as f:
            json.dump(payload, f, indent=2)
        os.replace(tmp_path, LIVE_STATUS_PATH)
    except Exception as exc:
        print(f"[orchestrator] WARNING: write_live_status failed: {exc}", flush=True)


def append_handoff_history(data, outcome, next_login):
    is_new = not os.path.exists(HANDOFF_HISTORY_PATH)
    with open(HANDOFF_HISTORY_PATH, "a", newline="") as f:
        writer = csv.writer(f)
        if is_new:
            f.write(HANDOFF_HISTORY_HEADER)
        writer.writerow([
            datetime.datetime.now().isoformat(),
            data.get("login", ""),
            data.get("reason", ""),
            data.get("pnl", ""),
            data.get("symbol", ""),
            data.get("magic", ""),
            data.get("time", ""),
            outcome,
            next_login,
        ])


def check_ea_heartbeat(cfg, current_login, switch_time):
    try:
        now = time.time()
        grace = cfg["heartbeat_grace_seconds"]
        if now - switch_time < grace:
            return {"alive": True, "detail": "within grace period after switch", "age_seconds": None}

        path = os.path.join(common_files_dir(), cfg["heartbeat_filename"])
        if not os.path.exists(path):
            return {"alive": False,
                    "detail": "no heartbeat file — EA may not be attached to any chart on this terminal",
                    "age_seconds": None}

        age = now - os.path.getmtime(path)
        data = parse_kv_file(path)
        hb_login = data.get("login")
        timeout = cfg["heartbeat_timeout_seconds"]

        if hb_login != str(current_login):
            return {"alive": False,
                    "detail": f"heartbeat still shows login={hb_login} (expected {current_login}) — "
                              f"EA not yet running on this account",
                    "age_seconds": age}
        if age > timeout:
            return {"alive": False,
                    "detail": f"heartbeat stale ({age:.0f}s old, timeout {timeout}s) — EA may have stopped",
                    "age_seconds": age}

        return {"alive": True, "detail": "ok", "age_seconds": age}
    except Exception as exc:
        return {"alive": None, "detail": f"heartbeat check failed: {exc}", "age_seconds": None}


def positions_count(symbol_filter=None, magic_filter=None):
    positions = mt5.positions_get(symbol=symbol_filter) if symbol_filter else mt5.positions_get()
    if positions is None:
        return 0
    if magic_filter is not None:
        positions = [p for p in positions if p.magic == int(magic_filter)]
    return len(positions)


def wait_until_flat(symbol_filter, magic_filter, poll_interval):
    waited = 0
    while True:
        n = positions_count(symbol_filter, magic_filter)
        if n == 0:
            return
        if waited % FLAT_WAIT_WARN_INTERVAL_SECONDS == 0:
            print(f"[orchestrator] waiting for account to go flat — {n} position(s) still open "
                  f"(EA should be closing them itself)", flush=True)
        time.sleep(poll_interval)
        waited += poll_interval


def pick_next_account(accounts, maxed_logins_today, current_index):
    n = len(accounts)
    for step in range(1, n + 1):
        idx = (current_index + step) % n
        if int(accounts[idx]["login"]) not in maxed_logins_today:
            return idx
    return None


def handle_handoff(cfg, state, accounts, handoff_path):
    data = parse_kv_file(handoff_path)
    login = data.get("login")
    reason = data.get("reason", "?")
    pnl = data.get("pnl", "?")
    print(f"[orchestrator] Handoff signal: login={login} reason={reason} pnl={pnl}", flush=True)

    current_account = accounts[state["current_index"]]
    symbol_filter = current_account.get("symbol")
    magic_filter = current_account.get("magic")

    wait_until_flat(symbol_filter, magic_filter, cfg["poll_interval_seconds"])
    print("[orchestrator] Account confirmed flat.", flush=True)

    os.remove(handoff_path)

    day = today_str()
    maxed_today = state["maxed_today"].setdefault(day, [])
    if reason in DAILY_LIMIT_REASONS and int(current_account["login"]) not in maxed_today:
        maxed_today.append(int(current_account["login"]))

    next_idx = pick_next_account(accounts, set(maxed_today), state["current_index"])
    if next_idx is None:
        print(f"[orchestrator] All {len(accounts)} accounts have hit their daily limit for {day}. "
              f"Idling until the next day.", flush=True)
        append_handoff_history(data, outcome="ALL_MAXED", next_login="")
        save_state(state)
        return

    next_login = accounts[next_idx]["login"]
    if not mt5_login(accounts[next_idx], cfg["mt5_terminal_path"]):
        print("[orchestrator] Switch failed — will retry on the next loop iteration.", flush=True)
        append_handoff_history(data, outcome="LOGIN_FAILED", next_login=next_login)
        return

    append_handoff_history(data, outcome="SWITCHED", next_login=next_login)
    state["current_index"] = next_idx
    save_state(state)
    return True


def main():
    cfg = load_config(CONFIG_PATH)
    state = load_state()
    accounts = cfg["accounts"]

    if state["current_index"] >= len(accounts):
        state["current_index"] = 0

    if not mt5_login(accounts[state["current_index"]], cfg["mt5_terminal_path"]):
        print("[orchestrator] Initial login failed, aborting.", flush=True)
        sys.exit(1)
    save_state(state)

    switch_time = time.time()
    last_heartbeat_warn_time = 0.0
    last_seen_day = today_str()

    print(f"[orchestrator] Watching for handoff signal '{cfg['handoff_filename']}' "
          f"every {cfg['poll_interval_seconds']}s.", flush=True)

    try:
        while True:
            day = today_str()
            if day != last_seen_day:
                print(f"[orchestrator] New day ({day}) — clearing exhausted-accounts list.", flush=True)
                state["maxed_today"].pop(last_seen_day, None)
                last_seen_day = day
                save_state(state)

            handoff_path = os.path.join(common_files_dir(), cfg["handoff_filename"])
            if os.path.exists(handoff_path):
                try:
                    if handle_handoff(cfg, state, accounts, handoff_path):
                        switch_time = time.time()
                        last_heartbeat_warn_time = 0.0
                except Exception as exc:
                    print(f"[orchestrator] ERROR handling handoff: {exc}", flush=True)

            current_login = accounts[state["current_index"]]["login"]
            ea_status = check_ea_heartbeat(cfg, current_login, switch_time)
            if ea_status["alive"] is False:
                now_t = time.time()
                if now_t - last_heartbeat_warn_time > HEARTBEAT_WARN_REPEAT_SECONDS:
                    print(f"[orchestrator] WARNING: {ea_status['detail']}", flush=True)
                    last_heartbeat_warn_time = now_t

            write_live_status(accounts, state, ea_status)
            time.sleep(cfg["poll_interval_seconds"])
    except KeyboardInterrupt:
        print("[orchestrator] Stopping.", flush=True)
    finally:
        mt5.shutdown()


if __name__ == "__main__":
    main()
