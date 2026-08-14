# Creed Infrastructure — CREED.ai Educa

Infraestrutura em **EKS** (ADR-001). Responsabilidade dos donos de infra;
o restante do time interage com o pipeline, não com o cluster.

## Componentes

| Componente | Onde roda | Observação |
|---|---|---|
| Front-end | Pod (Nginx servindo estáticos) | Dentro do EKS |
| Back-end | Pod (Uvicorn) | Dentro do EKS |
| PostgreSQL | **RDS gerenciado** | Fora do cluster — nunca banco stateful em pod |
| N8N | Pod stateful + PVC | Self-hosted por orçamento (ADR-001, 2.1) |
| Migrations | **Job dedicado** | `migration-job.yaml` — nunca no startup |

## Ordem de deploy

1. `migration-job.yaml` roda (`helm.sh/hook: pre-upgrade`)
2. Job conclui com sucesso
3. Pods da aplicação sobem

Se o Job falhar, o deploy para — a aplicação não sobe contra um schema
inconsistente.

## Pendências (ADR-001)

- [ ] Confirmar o que a agência já provê de trilhos de EKS antes de construir
      plataforma do zero (cluster compartilhado, ECR, ingress padrão).
- [ ] Definir os 1–2 donos de infra.
- [ ] N8N: volume persistente + schema Postgres dedicado no RDS, modo single.
