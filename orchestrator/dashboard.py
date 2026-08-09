#!/usr/bin/env python3
"""
AjipSnD multi-account rotation dashboard (Streamlit).

Reads read-only snapshots orchestrator.py writes to disk — accounts.json
(login/server/symbol only, password is never read or rendered), state.json,
live_status.json, handoff_history.csv — plus each account's own
AjipSnD_Batches_*.csv written directly by the EA (AjipSnD_Trade.mqh:
FlushBatchCSV). No MetaTrader5 import here on purpose: this runs as a
separate process and must never contend with orchestrator.py's own MT5
terminal session for the login slot.

Run:
    streamlit run dashboard.py --server.address 0.0.0.0 --server.port 8501

Auth: single shared password, sha256 hash stored in dashboard_auth.json
(gitignored). Create it first — see README.md. This is a basic gate, not
real access control (no rate-limiting, no TLS) — if exposed to the
internet, put it behind a reverse proxy or restrict the port to your own
IP at the VPS firewall.
"""

import datetime
import glob
import hashlib
import json
import os

import pandas as pd
import streamlit as st

HERE = os.path.dirname(__file__)
ACCOUNTS_PATH = os.path.join(HERE, "accounts.json")
STATE_PATH = os.path.join(HERE, "state.json")
LIVE_STATUS_PATH = os.path.join(HERE, "live_status.json")
HANDOFF_HISTORY_PATH = os.path.join(HERE, "handoff_history.csv")
AUTH_PATH = os.path.join(HERE, "dashboard_auth.json")

STALE_MULTIPLIER = 3  # warn if live_status.json is older than poll_interval * this

st.set_page_config(page_title="AjipSnD Rotation Dashboard", layout="wide")


# ------------------------------------------------------------------
# Auth
# ------------------------------------------------------------------
def check_auth():
    if not os.path.exists(AUTH_PATH):
        st.error(
            "No dashboard password set. Create orchestrator/dashboard_auth.json "
            "first — see README.md for the one-line command."
        )
        st.stop()

    with open(AUTH_PATH) as f:
        expected_hash = json.load(f)["password_hash"]

    if st.session_state.get("authenticated"):
        return

    st.title("AjipSnD Dashboard")
    pw = st.text_input("Password", type="password")
    if not pw:
        st.stop()
    if hashlib.sha256(pw.encode()).hexdigest() != expected_hash:
        st.error("Wrong password.")
        st.stop()
    st.session_state["authenticated"] = True
    st.rerun()


check_auth()


# ------------------------------------------------------------------
# Data loading — plain file reads only, never the MT5 API.
# ------------------------------------------------------------------
def load_json(path, default=None):
    if not os.path.exists(path):
        return default
    with open(path) as f:
        return json.load(f)


def load_raw_config():
    return load_json(ACCOUNTS_PATH, {"accounts": [], "poll_interval_seconds": 5})


def load_public_accounts():
    # Deliberately drops "password" — this is a display layer, the field
    # should never even be held in a variable here.
    cfg = load_raw_config()
    return [
        {
            "login": int(a["login"]),
            "server": a["server"],
            "symbol": a.get("symbol", ""),
            "magic": a.get("magic", ""),
        }
        for a in cfg.get("accounts", [])
    ]


def load_handoff_history():
    if not os.path.exists(HANDOFF_HISTORY_PATH):
        return pd.DataFrame()
    df = pd.read_csv(HANDOFF_HISTORY_PATH)
    return df.sort_values("handled_at", ascending=False)


def find_batch_csv(files_dir, login):
    if not files_dir or not os.path.isdir(files_dir):
        return None
    matches = glob.glob(os.path.join(files_dir, f"AjipSnD_Batches_*_{login}.csv"))
    return matches[0] if matches else None


def load_batch_df(path):
    df = pd.read_csv(path)
    df["CloseTime"] = pd.to_datetime(df["CloseTime"], format="%Y.%m.%d %H:%M", errors="coerce")
    df = df.sort_values("CloseTime")
    df["CumulativePnL"] = df["TotalRealizedPnL"].cumsum()
    return df


# ------------------------------------------------------------------
# Live panel
# ------------------------------------------------------------------
@st.fragment(run_every="15s")
def render_live_panel(poll_interval_seconds):
    live = load_json(LIVE_STATUS_PATH)
    if not live:
        st.info("No live_status.json yet — orchestrator hasn't completed a cycle.")
        return

    updated_at = datetime.datetime.fromisoformat(live["updated_at"])
    age_seconds = (datetime.datetime.now() - updated_at).total_seconds()
    st.caption(f"Updated {live['updated_at']} ({age_seconds:.0f}s ago)")
    if age_seconds > poll_interval_seconds * STALE_MULTIPLIER:
        st.warning("Stale — orchestrator.py may not be running.")

    ea_alive = live.get("ea_alive")
    ea_detail = live.get("ea_status_detail", "unknown")
    if ea_alive is False:
        st.error(f"EA not detected on this account: {ea_detail}")
    elif ea_alive is None and "ea_alive" in live:
        st.info(f"EA status unknown: {ea_detail}")

    cols = st.columns(5)
    cols[0].metric("Active login", live["current_login"])
    cols[1].metric("Balance", f"{live['balance']:.2f}")
    cols[2].metric("Equity", f"{live['equity']:.2f}")
    cols[3].metric("Floating PnL", f"{live['floating_pnl']:.2f}")
    cols[4].metric("Open positions", len(live["positions"]))

    if live["positions"]:
        st.dataframe(pd.DataFrame(live["positions"]), width="stretch", hide_index=True)


# ------------------------------------------------------------------
# Page
# ------------------------------------------------------------------
st.title("AjipSnD — Multi-Account Rotation Dashboard")

raw_cfg = load_raw_config()
accounts = load_public_accounts()
state = load_json(STATE_PATH, {"current_index": 0, "maxed_today": {}})
live = load_json(LIVE_STATUS_PATH, {})
files_dir = live.get("files_dir")

if st.button("Refresh now"):
    st.rerun()

st.subheader("Live")
render_live_panel(raw_cfg.get("poll_interval_seconds", 5))

st.subheader("Rotation")
today = datetime.date.today().isoformat()
maxed_today = set(state.get("maxed_today", {}).get(today, []))
current_login = (
    accounts[state["current_index"]]["login"]
    if accounts and state.get("current_index", 0) < len(accounts)
    else None
)

rows = []
all_batches = {}
for a in accounts:
    login = a["login"]
    path = find_batch_csv(files_dir, login)
    df = load_batch_df(path) if path else pd.DataFrame()
    all_batches[login] = df

    if login == current_login:
        status = "ACTIVE"
    elif login in maxed_today:
        status = "maxed today"
    else:
        status = "waiting"

    today_df = df[df["CloseTime"].dt.date.astype(str) == today] if not df.empty else df
    wins = int(df["Wins"].sum()) if not df.empty else 0
    losses = int(df["Losses"].sum()) if not df.empty else 0
    win_rate = f"{wins / (wins + losses) * 100:.0f}%" if (wins + losses) > 0 else "—"

    rows.append({
        "Login": login,
        "Server": a["server"],
        "Status": status,
        "Floating PnL (live)": round(live["floating_pnl"], 2) if login == current_login and live else None,
        "Today's realized PnL": round(today_df["TotalRealizedPnL"].sum(), 2) if not today_df.empty else 0.0,
        "All-time realized PnL": round(df["TotalRealizedPnL"].sum(), 2) if not df.empty else 0.0,
        "Trades": int(df["PositionCount"].sum()) if not df.empty else 0,
        "Win rate": win_rate,
        "Last activity": df["CloseTime"].max() if not df.empty else None,
    })

st.dataframe(pd.DataFrame(rows), width="stretch", hide_index=True)

st.subheader("Cumulative realized PnL by account")
chart_frames = []
for login, df in all_batches.items():
    if df.empty:
        continue
    tmp = df[["CloseTime", "CumulativePnL"]].copy()
    tmp["Login"] = str(login)
    chart_frames.append(tmp)

if chart_frames:
    chart_df = pd.concat(chart_frames)
    pivot = chart_df.pivot_table(index="CloseTime", columns="Login", values="CumulativePnL", aggfunc="last")
    pivot = pivot.ffill()
    st.line_chart(pivot)
else:
    st.info("No batch history yet.")

st.subheader("Handoff history")
history = load_handoff_history()
if history.empty:
    st.info("No handoffs recorded yet.")
else:
    st.dataframe(history, width="stretch", hide_index=True)
