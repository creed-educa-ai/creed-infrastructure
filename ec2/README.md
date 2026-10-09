# EC2 — produção (ADR-0007)

Caddy (HTTPS e roteamento) na frente do Keycloak, num `docker compose` só. O banco é
o RDS. N8N e back entram nas próximas fases.

| Caminho público | Vai para |
|---|---|
| `https://<IP>/auth/admin*` | **404** — console só por túnel |
| `https://<IP>/auth/*` | Keycloak (páginas do realm, link do convite) |
| qualquer outro | `CREED ok` (até o back entrar) |

## Layout na instância

```
/opt/creed/
├── .env                      ← senhas reais, chmod 600, nunca no git
├── creed-infrastructure/     ← git clone (este repo)
│   └── ec2/
│       └── .env → /opt/creed/.env
└── creed-backend/            ← git clone (o realm-creed.json vem dele)
```

Os dois repositórios são públicos: o clone não precisa de credencial.

## Primeira vez

```bash
cd /opt/creed
git clone https://github.com/creed-educa-ai/creed-infrastructure.git
git clone https://github.com/creed-educa-ai/creed-backend.git
ln -s /opt/creed/.env /opt/creed/creed-infrastructure/ec2/.env
```

Preencha o `/opt/creed/.env` a partir do [`.env.example`](.env.example). Os segredos
novos se geram sem passar pelo histórico do terminal:

```bash
echo "KEYCLOAK_CLIENT_SECRET=$(openssl rand -hex 32)" >> /opt/creed/.env
echo "KEYCLOAK_ADMIN_PASSWORD=$(openssl rand -hex 16)" >> /opt/creed/.env
```

## Subir / atualizar

```bash
cd /opt/creed/creed-infrastructure/ec2
docker compose up -d
docker compose logs -f keycloak     # primeira subida: 1–3 min (o Keycloak se compila)
```

Conferir, de fora da EC2:

```bash
curl https://<IP>/auth/realms/creed                 # JSON do realm
curl -o /dev/null -w '%{http_code}\n' https://<IP>/auth/admin/   # 404
```

## Console de admin do Keycloak

```bash
ssh -L 18080:localhost:8080 creed-ec2
```

e abra <http://localhost:18080/auth/admin>. Usuário e senha: `KEYCLOAK_ADMIN_*` do `.env`.

## Cuidados

- **Nunca apague o volume `creed_caddy_data`** (nada de `docker compose down -v`): é
  onde o certificado mora, e o Let's Encrypt emite no máximo 5 iguais por semana.
- **Mudar o `realm-creed.json` não muda o realm em produção.** O `--import-realm` só
  importa se o realm ainda não existe. Como aplicar mudança depois disso é pendência.
