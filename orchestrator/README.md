# AjipSnD multi-account rotation orchestrator

Rotates a single MT5 terminal across multiple accounts. When the current
account's EA hits daily target/max-loss, it writes a handoff signal to
`Common\Files`. The orchestrator detects it, confirms the account is flat,
then calls `mt5.login()` to rotate to the next account.

See the AjipIDM orchestrator README for full details on the architecture —
the setup is identical.

## Setup

```bash
pip install -r requirements.txt
cp accounts.example.json accounts.json   # fill in real credentials
```

Set dashboard password:
```bash
python -c "import hashlib, getpass, json; json.dump({'password_hash': hashlib.sha256(getpass.getpass('Dashboard password: ').encode()).hexdigest()}, open('orchestrator/dashboard_auth.json', 'w'))"
```

## Run

```bash
python run.py --dashboard-port 8502
```

Or separately:
```bash
python orchestrator.py
streamlit run dashboard.py --server.address 0.0.0.0 --server.port 8502 --server.headless true
```

## EA config

Make sure the EA has these inputs:
- `InpHandoffEnabled = true`
- `InpHandoffFile = "AjipSnD_Handoff.csv"`
- `InpHeartbeatFile = "AjipSnD_Heartbeat.csv"`
