# EC2 — produção (ADR-0007)

Caddy (HTTPS e roteamento) na frente do back, do Keycloak e do N8N, num `docker
compose` só. O banco é o RDS.

| Endereço público | Vai para |
|---|---|
| `https://<IP>/auth/admin*` | **404** — console só por túnel |
| `https://<IP>/auth/*` | Keycloak (páginas do realm, link do convite) |
| `https://<IP>/api/*` | back (FastAPI) |
| `https://<IP>:5679` | editor do N8N, atrás de senha compartilhada + login do N8N |
| qualquer outro | `CREED ok` |

O back fala com o Keycloak e com o N8N pela rede interna do compose — nada disso passa
pelos endereços acima.

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
echo "KC_BOOTSTRAP_ADMIN_USERNAME=admin-temporario" >> /opt/creed/.env
echo "KC_BOOTSTRAP_ADMIN_PASSWORD=$(openssl rand -hex 16)" >> /opt/creed/.env
echo "N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)" >> /opt/creed/.env
```

Todo segredo novo vai **também** para o Parameter Store, em `/creed/prod/<VARIÁVEL>`
(ver `creed-ai-context/context/infraestrutura.md`). O `N8N_ENCRYPTION_KEY` é o que mais
importa: perdido, as credenciais salvas no N8N ficam ilegíveis.

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

## Back e deploy

O back **não sobe com `git pull`**: a imagem vem pronta do GitHub. Produção publica a
partir da `main` do `creed-backend` (CREED-285):

```
merge na main ──▶ workflow imagem.yml gera ghcr.io/creed-educa-ai/creed-backend:<commit>
              ──▶ (Session Manager) a EC2 roda: ./deploy.sh <commit>
```

O [`deploy.sh`](deploy.sh), na ordem — e ela importa (princípio inegociável #2):

1. baixa a imagem do commit;
2. roda `alembic upgrade head` num **container descartável** dessa imagem;
3. só se a migration passar, recria o container do back;
4. espera o `/health` responder e **só então** grava o commit em `BACK_TAG`, no `.env`.

Migration falhou → o script para no passo 2, e o back antigo segue no ar com o banco
como estava. Back não respondeu → o script mostra o log e para, **sem voltar sozinho
à versão anterior**: a migration já rodou, e a imagem antiga pode não entender o
banco novo. Quem decide é uma pessoa.

À mão, de dentro da EC2 (como `ec2-user`), funciona igual:

```bash
cd /opt/creed/creed-infrastructure/ec2
./deploy.sh <commit>
grep BACK_TAG /opt/creed/.env      # qual commit está no ar
```

O pacote da imagem no GHCR precisa estar **público**, para a EC2 baixar sem senha.

Mudança **neste** compose (serviço novo, variável nova) não chega com o deploy do
back: é `git pull` neste clone e `docker compose up -d`, à mão, com alguém olhando.

## Editor do N8N

**Senha compartilhada** (a primeira tela, pedida pelo Caddy). O `.env` guarda o
*hash*, não a senha — entre aspas simples, porque o hash tem `$`:

```bash
docker run --rm caddy:2.11 caddy hash-password --plaintext 'a-senha-escolhida'
# no /opt/creed/.env:
#   N8N_BASIC_AUTH_USER=time
#   N8N_BASIC_AUTH_HASH='$2a$14$...'
docker compose up -d caddy        # o Caddy relê a senha
```

A senha em si vai para o Parameter Store (`/creed/prod/N8N_BASIC_AUTH_PASSWORD`,
`SecureString`), que é de onde o time a pega.

**Primeiro acesso:** abra `https://<IP>:5679`, passe pela senha compartilhada, e o
N8N pede para criar o **dono** (*owner*). Quem cria vira o admin do N8N: ligue a
verificação em duas etapas dele (*Settings → Personal → Two-factor authentication*).
O resto do time entra por convite (*Settings → Users → Invite*): sem SMTP, o N8N
mostra o link do convite para copiar e mandar.

**Security group:** a porta **5679** precisa de regra de entrada (TCP, `0.0.0.0/0`).

**Plano B, se o Caddy estiver fora:** `ssh -L 15678:localhost:5678 creed-ec2` e
<http://localhost:15678>.

**Webhooks:** a URL que o editor mostra (`http://n8n:5678/webhook/...`) é a da rede
interna — é a que o back usa. Ela não abre do seu navegador, e é assim de propósito.

## Console de admin do Keycloak

```bash
ssh -L 18080:localhost:8080 creed-ec2
```

e abra <http://localhost:18080/auth/admin>. Na primeira vez, entre com o
`KC_BOOTSTRAP_ADMIN_*` do `.env`, crie no realm `master` um admin **por pessoa**
(papel `admin`), entre com ele, apague o temporário e **remova as duas linhas
`KC_BOOTSTRAP_ADMIN_*` do `.env`**.

## Cuidados

- **Nunca apague os volumes** (nada de `docker compose down -v`). O `creed_caddy_data`
  guarda o certificado — o Let's Encrypt emite no máximo 5 iguais por semana. O
  `creed_n8n_data` é o único estado do N8N fora do RDS.
- **Versão do N8N é fixa** (`n8nio/n8n:2.43.4`) e igual à do compose local. Atualizar
  é trocar nos dois lugares, de propósito, lendo o que mudou.
- **Mudar o `realm-creed.json` não muda o realm em produção.** O `--import-realm` só
  importa se o realm ainda não existe. Como aplicar mudança depois disso é pendência.
