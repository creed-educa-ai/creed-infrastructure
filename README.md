# Creed Infrastructure — CREED.ai Educa

Infraestrutura em **AWS Amplify + EC2** ([ADR-0007](https://github.com/creed-educa-ai/creed-ai-context/blob/main/decisoes/adrs/0007-amplify-e-ec2-no-lugar-do-eks.md)).
Responsabilidade dos donos de infra; o restante do time interage com o pipeline, não
com a instância.

> **Este repo descrevia EKS até 2026-09-12.** O desenho de cluster foi aposentado: não
> havia dono de infra e a pendência #1 do ADR-001 — o que a agência provê de trilhos de
> EKS — nunca foi respondida. O `migration-job.yaml` continua versionado como
> referência, mas **nada o consome**.

## Componentes

| Componente | Onde roda | Observação |
|---|---|---|
| Front-end | **AWS Amplify** | build estático; CDN, TLS e preview por PR gerenciados |
| Back-end | Container na EC2 (Uvicorn) | mesmo `docker-compose` do ambiente local |
| Keycloak | Container na EC2 | schema `keycloak` no RDS |
| N8N | Container na EC2 + volume | self-hosted por orçamento (ADR-001, 2.1) |
| PostgreSQL | **RDS gerenciado** | fora da instância — nunca banco no disco da EC2 |
| Migrations | **Passo do pipeline** | container descartável — nunca no startup |

Uma EC2 só, três containers, um `docker-compose` — o mesmo que roda na máquina de quem
desenvolve. Local e ambiente real têm a mesma topologia de propósito.

## Ordem de deploy

```
1. Pipeline sobe um container descartável: alembic upgrade head
2. Esse container termina com código 0
3. Só então o container do back é recriado na imagem nova
```

Migration falhou → o passo 3 não acontece, e a instância **continua servindo a versão
anterior**. A aplicação nunca sobe contra um schema inconsistente.

O front não entra nesse fluxo: o Amplify publica o build por conta própria, no push.

## Estado fora do RDS

O **volume do N8N** é o único dado que não vive no RDS. É o que precisa de backup de
disco, e o que não volta sozinho se a instância morrer — back e Keycloak voltam sem
perda.

## Pendências

- [ ] Definir os 1–2 donos de infra (pendência herdada do ADR-001).
- [ ] Onde roda o passo de migration no pipeline, e com qual credencial de RDS.
- [ ] Backup do volume do N8N.
- [ ] Domínio e TLS nas duas pontas — Amplify e EC2. É o que fecha o CORS e o hostname
      do realm do Keycloak.
- [ ] Tamanho da instância: três containers mais o overhead de JVM do Keycloak.
