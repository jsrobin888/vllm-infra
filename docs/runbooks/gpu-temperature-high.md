# =============================================================================
# Runbook: GPU Temperature High
# Phase 56: Incident Response — Stage 165
# =============================================================================

## Alert: GPUTemperatureHigh / GPUTemperatureCritical

**Severity:** Warning (>85°C) / Critical (>92°C)
**Category:** GPU Hardware

---

## Immediate Actions

### 1. Check current temperatures

```bash
nvidia-smi --query-gpu=index,temperature.gpu,power.draw,fan.speed --format=csv
```

### 2. Reduce power to cool down

```bash
# Immediate: reduce power limit
scripts/gpu/power-manager.sh profile power-saver

# Or set specific limit
sudo nvidia-smi -i <gpu_id> -pl 200
```

### 3. Check airflow

- Verify datacenter HVAC is functioning
- Check for blocked airflow around server
- Verify fan operation: `nvidia-smi --query-gpu=fan.speed --format=csv`

### 4. Check workload

```bash
# Is this GPU overloaded?
nvidia-smi --query-gpu=utilization.gpu,utilization.memory --format=csv
docker stats --no-stream --filter "name=vllm"
```

---

## Root Causes

| Cause | Fix |
|-------|-----|
| Ambient temp too high | HVAC repair, move server |
| Blocked airflow | Clean dust, rearrange cables |
| Fan failure | Replace fan, RMA GPU |
| Overclocked/over-powered | Reduce power limit, reset clocks |
| Thermal paste degraded | Repaste (vendor service) |
| Sustained 100% utilization | Add capacity, reduce load |

---

## Recovery

Once temperature drops below 75°C:
```bash
# Restore normal power profile
scripts/gpu/power-manager.sh profile balanced
```

---

## Prevention

- Set power limits proactively (85% of max)
- Monitor temperature trends in Grafana
- Alert at 80°C (warning) to catch issues early
- Quarterly datacenter thermal audit
