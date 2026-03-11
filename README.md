# Observability Stack Deployment
> Grafana · Prometheus · Loki · Mimir · Promtail on AWS EC2

---

## Prerequisites

- **AMI:** Ubuntu 22.04 or 24.04 LTS
- **Instance type:** t3.medium or larger (minimum 2 vCPU, 4 GB RAM)
- **Storage:** 20 GB or more

## Deployment Steps

**Step 1 — SSH into your EC2 instance**
```bash
ssh -i your-key.pem ubuntu@<EC2-PUBLIC-IP>
```

**Step 2 — Create the script**

Open a new file using nano:
```bash
nano deploy_observability_stack.sh
```
Paste the full script content, then save with `Ctrl+X` → `Y` → `Enter`.

**Step 3 — Make it executable**
```bash
chmod +x deploy_observability_stack.sh
```

**Step 4 — Run the script**
```bash
sudo ./deploy_observability_stack.sh
```

---

## Accessing the Stack

| Service    | URL                              | Port | Login       |
|------------|----------------------------------|------|-------------|
| Grafana    | http://\<EC2-IP\>:3000           | 3000 | admin/admin |
| Prometheus | http://\<EC2-IP\>:9090           | 9090 | -           |
| Loki       | http://\<EC2-IP\>:3100/ready     | 3100 | -           |
| Mimir      | http://\<EC2-IP\>:9009/ready     | 9009 | -           |

> ⚠️ Change the Grafana default password immediately after first login.

---

## Verification

**Check all services are running:**
```bash
sudo systemctl status prometheus loki mimir grafana-server promtail
```

**Check health endpoints:**
```bash
curl http://localhost:9090/-/healthy   # Prometheus
curl http://localhost:3100/ready       # Loki
curl http://localhost:9009/ready       # Mimir
```

**Verify in Grafana:**
1. Go to **Connections → Data sources** → click each → **Save & Test**
2. Go to **Explore** → select **Mimir** → run: `up`
3. Go to **Explore** → select **Loki** → run: `{job="varlogs"}`


