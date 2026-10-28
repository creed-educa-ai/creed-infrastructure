# EC2 — produção (ADR-0007)

Caddy (HTTPS e roteamento) na frente do back, do Keycloak e do N8N, num `docker
compose` só. O banco é o RDS.

| Endereço público | Vai para |
|---|---|
| `https://<IP>/auth/admin*` | **404** — console só por túnel |
| `https://<IP>/auth/realms/master*` | **404** — o login dos admins do Keycloak também só por túnel |
| `https://<IP>/auth/*` | Keycloak (páginas do realm, link do convite) |
| `https://<IP>/api/*` | back (FastAPI) |
| `https://<IP>:5679/mcp-server/*`, `/mcp-oauth/*`, `/.well-known/oauth-*` | servidor MCP do N8N, **sem** a senha compartilhada — protegido pelo token do N8N |
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

**Um deploy por vez.** O script trava o `/opt/creed/deploy.lock` (`flock`) antes de
tudo: um segundo deploy, do workflow ou à mão, sai na hora com "outro deploy em
andamento", em vez de rodar uma segunda migration junto com a primeira.

**Sem `BACK_TAG` no `.env`, o back não sobe** — de propósito. A imagem reserva do
compose é a tag `rode-o-deploy-sh`, que não existe: o erro de pull já diz o que
fazer. A `:main` não serve de reserva porque muda antes de a migration rodar.

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

**MCP (ligar o Claude aos workflows):** o servidor MCP do N8N fica **fora** da senha
compartilhada. Não há como passar pelas duas: a senha do Caddy usa `Authorization:
Basic`, e o MCP manda o token do N8N no mesmo cabeçalho (`Bearer`). Quem protege
esses caminhos é o próprio N8N — token por pessoa, limite de tentativas por IP e 404
enquanto o MCP estiver desligado. Para usar:

1. No editor, ligue o MCP nas configurações do N8N e gere o seu token. Libere, em cada
   workflow, o acesso por MCP — workflow não liberado fica invisível para o Claude.
2. Conecte com a URL `https://<IP>:5679/mcp-server/http`: no Claude Code, com o token
   no cabeçalho `Authorization: Bearer <token>`; no claude.ai, como conector, pelo
   login OAuth (a tela de consentimento é do editor e pede a senha compartilhada).

Os caminhos liberados foram conferidos no N8N 2.43.4. Ao atualizar o N8N, confira se
continuam os mesmos.

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

**O realm `master` tem *Frontend URL* próprio: `http://localhost:18080/auth`.** A página
do console vem pelo túnel, mas o login dele é montado com o endereço público
(`KC_HOSTNAME`), e o Caddy responde 404 para `/auth/realms/master*`. Sem o *Frontend
URL*, o console abre em "somethingWentWrong" (aconteceu em 2026-10-27). Num Keycloak
novo, aplique **antes** de abrir o console, com o admin temporário:

```bash
docker compose exec keycloak /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080/auth --realm master --user <admin>
docker compose exec keycloak /opt/keycloak/bin/kcadm.sh update realms/master \
  -s 'attributes.frontendUrl=http://localhost:18080/auth'
```

O `kcadm.sh` fala direto com a porta 8080, sem passar pelo Caddy. Por isso o túnel
precisa ser sempre na porta local **18080**.

**Proteção contra força bruta**, nos dois realms (*Realm settings → Security
defenses → Brute force detection*, modo *Lockout temporarily*). No `creed` ela já
vem do `realm-creed.json` para quem importar o realm do zero; na produção, que
importou antes, foi ligada à mão. No `master`, que não vem de arquivo, sempre à mão.

## Conta na plataforma (enquanto não há cadastro pelo site)

O back ainda não cria usuário no Keycloak (o `POST /users` recebe um `keycloak_id`
pronto) e o front não tem tela de admin. Até isso existir, cada conta nasce à mão,
em duas partes:

1. **Keycloak**, pelo console, no realm `creed`: *Users → Create new user* com e-mail
   como username, *Email verified* ligado e nenhuma ação obrigatória; em
   *Credentials*, senha com **Temporary desligado** (ligado, o login responde
   "Account is not fully set up", que na tela parece senha errada); em *Role
   mapping*, o papel; em *Details*, copie o **ID**.
2. **Banco**, pelo DBeaver com túnel SSH até a EC2 (host do RDS, usuário
   `creed_app`). Um comando só, para não sobrar linha pela metade:

```sql
WITH p AS (
  INSERT INTO participants (id, name, status)
  VALUES (gen_random_uuid(), '<nome>', 'ACTIVE')
  RETURNING id
), l AS (
  INSERT INTO links (id, participant_id, organization_id, type, role)
  SELECT gen_random_uuid(), p.id, '<organização>', 'EMPREGO', '<ADMIN|GESTOR|RESPONDENTE>'
  FROM p
  RETURNING id
)
INSERT INTO "user" (id, keycloak_id, name, email, status, link_id)
SELECT gen_random_uuid(), '<ID do Keycloak>', '<nome>', '<e-mail em minúsculas>', 'ACTIVE', l.id
FROM l;
```

- O papel do vínculo e o do Keycloak têm que ser **o mesmo**.
- Enums vão em maiúsculas: o banco guarda o **nome** do enum, não o valor da API.
- Enquanto a tabela `organizations` não tiver migration, a organização é a
  provisória `00000000-0000-0000-0000-000000000001` — a mesma do seed local. O login
  funciona; telas que leem organização, não.

## Cuidados

- **Nunca apague os volumes** (nada de `docker compose down -v`). O `creed_caddy_data`
  guarda o certificado — o Let's Encrypt emite no máximo 5 iguais por semana. O
  `creed_n8n_data` é o único estado do N8N fora do RDS.
- **Versão do N8N é fixa** (`n8nio/n8n:2.43.4`) e igual à do compose local. Atualizar
  é trocar nos dois lugares, de propósito, lendo o que mudou.
- **Mudar o `realm-creed.json` não muda o realm em produção.** O `--import-realm` só
  importa se o realm ainda não existe. Como aplicar mudança depois disso é pendência.
- **Mudou o `Caddyfile`? Recrie o Caddy:** `docker compose up -d --force-recreate caddy`.
  O arquivo entra no container montado, e o `git pull` troca o arquivo em vez de
  editá-lo — o container segue lendo o antigo, e um `up -d` comum não recria nada,
  porque o compose do Caddy não mudou. Aconteceu em 2026-10-20: a rota `/api` não
  existia, e o `/api/...` respondia o `CREED ok` com status 200, parecendo
  funcionar. Para conferir, olhe o **conteúdo** da resposta, não só o código. O
  certificado fica no volume: recriar não pede um novo.

## Pendências de operação

- [ ] **Backup do disco da EC2** — o `creed_n8n_data` é o único estado fora do RDS.
      Política do *Data Lifecycle Manager* tirando snapshot diário do volume.
- [ ] **Conferir os backups automáticos do RDS** — retenção e janela.
- [ ] **Alertas** — *AWS Budget* avisando antes de os créditos acabarem, e alarme do
      CloudWatch no *status check* da EC2, com recuperação automática.
- [ ] **Fechar a porta 22** — trocar os túneis (console do Keycloak, DBeaver) pelo
      *port forwarding* do Session Manager. Fecha só depois que funcionar para quem usa.
- [ ] **Branch `main` no Amplify** — quando houver release, com as mesmas variáveis
      e a mesma reescrita da `dev`.
- [ ] **E-mail (SES) e LLM da esteira** — decisões antes de configuração: ver
      ADR-0006 e, para o LLM, um ADR que ainda não existe.
- [ ] **Limpeza no fim do semestre** — snapshots, volumes e o Elastic IP, que é
      cobrado quando fica desassociado.
