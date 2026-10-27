# Creed Infrastructure — CREED.ai Educa

Produção do CREED.ai Educa ([ADR-0007](https://github.com/creed-educa-ai/creed-ai-context/blob/main/decisoes/adrs/0007-amplify-e-ec2-no-lugar-do-eks.md),
que substituiu o EKS do ADR-001): front no **Amplify**, back, Keycloak e N8N numa
**EC2 única** com Docker Compose, banco no **RDS**.

## Componentes

| Componente | Onde roda | Observação |
|---|---|---|
| Front-end | **Amplify** | Build do `creed-frontend` a cada push na branch ligada; reescrita de SPA e `VITE_API_BASE_URL` configuradas no console |
| Back-end | Container na EC2 | Imagem vinda do GHCR, publicada pelo `deploy.sh` (CREED-285) |
| Keycloak | Container na EC2 | Estado no RDS (schema `keycloak`) |
| N8N | Container na EC2 + volume | Estado no RDS (schema `n8n`) **e** no volume — o único fora do RDS |
| Caddy | Container na EC2 | HTTPS (certificado do IP) e divisão do tráfego por caminho |
| PostgreSQL | **RDS** | Um schema por componente; nunca acessível pela internet |

## Onde está cada coisa

- [`ec2/`](ec2/) — compose de produção, Caddyfile, `deploy.sh` e o
  [README](ec2/README.md) de operação: subir, atualizar, deploy, consoles, cuidados.
- [`migration-job.yaml`](migration-job.yaml) — **aposentado**. Era o Job de migration
  do EKS; quem roda a migration agora é o `deploy.sh`, num container descartável,
  antes de recriar o back. O princípio é o mesmo: migration nunca no startup.

## Ordem de deploy do back

1. A imagem do commit é baixada.
2. `alembic upgrade head` roda num container descartável dessa imagem.
3. Só se a migration passar, o container do back é recriado.

Se a migration falhar, o deploy para — o back antigo segue no ar, com o banco como
estava. Detalhe em [`ec2/README.md`](ec2/README.md#back-e-deploy).

## Pendências

As de arquitetura estão no ADR-0007. As de operação estão no
[`ec2/README.md`](ec2/README.md#pendências-de-operação).
