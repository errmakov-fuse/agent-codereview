# ssm-tunnel-watch.ps1

Keeps an AWS SSM port-forward to the prod RDS (`inkhub-db`) open.
localhost:15432 forwards to inkhub-db:5432, through the bastion instance `i-029c240d2b484bc3b`.
If the tunnel drops, the script starts it again.

## Run

```powershell
powershell -ExecutionPolicy Bypass -File C:\Users\DenisErmakov\www\agent-codereview\tools\ssm-tunnel\ssm-tunnel-watch.ps1
```

Run it in its own terminal. Stop it with Ctrl+C.

Needs the AWS CLI, the Session Manager plugin, and a valid SSO login:

```powershell
aws sso login --profile InkhubDeveloperAccess-660505295667
```

## Behaviour

- Runs `aws ssm start-session` and waits until it exits.
- Restarts it after 5 s.
- If the tunnel lived less than 60 s, it doubles the wait each time, up to 120 s. A tunnel that keeps dying fast usually means the SSO login expired, so it prints the `aws sso login` hint.
- If port 15432 is already listening (another tunnel is open), it waits 30 s and checks again instead of starting a second one.

## Changing details

All settings are variables at the top of the script:

| Variable      | Meaning                                    |
|---------------|--------------------------------------------|
| `$Profile_`   | AWS CLI profile                            |
| `$Region`     | AWS region                                 |
| `$Target`     | Bastion EC2 instance id                    |
| `$RemoteHost` | RDS endpoint                               |
| `$LocalPort`  | Local port (remote port is fixed at 5432)  |
| `$MinDelay` / `$MaxDelay` | Restart backoff, in seconds    |

## Equivalent one-off command

```bash
aws ssm start-session --profile InkhubDeveloperAccess-660505295667 --region us-east-1 \
  --target i-029c240d2b484bc3b \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters host=inkhub-db.chuc67gvfvrq.us-east-1.rds.amazonaws.com,portNumber=5432,localPortNumber=15432
```
