# EC2 — produção (ADR-0007)

Caddy (HTTPS e roteamento) na frente do back, do Keycloak e do N8N, num `docker
compose` só. O banco é o RDS.

| Endereço público | Vai para |
|---|---|
| `https://<IP>/auth/admin*` | **404** — console só por túnel |
| `https://<IP>/auth/realms/master*` | **404** — o login dos admins do Keycloak também só por túnel |
| `https://<IP>/auth/*` | Keycloak (páginas do realm, link do convite) |
| `https://<IP>/api/v1/insights/callback*` | **404** — a volta da esteira de insights só chega pela rede interna |
| `https://<IP>/api/*` | back (FastAPI) |
| `https://<IP>:5679/mcp-server/*`, `/mcp-oauth/*`, `/.well-known/oauth-*` | servidor MCP do N8N, **sem** a senha compartilhada — protegido pelo token do N8N |
| `https://<IP>:5679` | editor do N8N, atrás de senha compartilhada + login do N8N |
| qualquer outro | `CREED ok` |

O back fala com o Keycloak e com o N8N pela rede interna do compose — nada disso passa
pelos endereços acima. O `insight-worker` também roda neste compose, ao lado do back, e
não tem endereço: ninguém o chama, é ele que chama o N8N.

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
3. só se a migration passar, recria o container do back **e o do `insight-worker`**
   (a mesma imagem, outro comando);
4. espera o `/health` do back responder e **só então** grava o commit em `BACK_TAG`, no
   `.env`. O worker não tem `/health`: o sinal dele está em "Esteira de insights".

Migration falhou → o script para no passo 2, e o back e o worker antigos seguem no ar
com o banco como estava. Back não respondeu → o script mostra o log e para, **sem
voltar sozinho à versão anterior**: a migration já rodou, e a imagem antiga pode não
entender o banco novo. Quem decide é uma pessoa.

**Um deploy por vez.** O script trava o `/opt/creed/deploy.lock` (`flock`) antes de
tudo: um segundo deploy, do workflow ou à mão, sai na hora com "outro deploy em
andamento", em vez de rodar uma segunda migration junto com a primeira.

**Sem `BACK_TAG` no `.env`, o back e o worker não sobem** — de propósito. A imagem reserva do
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

## Esteira de insights

A cada resposta enviada, o back grava um pedido de insight. O `insight-worker` (a mesma
imagem do back, com o comando `python -m app.workers.insights`) entrega o pedido ao N8N,
e o N8N devolve o texto em `/api/v1/insights/callback` (ADR-0010). Cada sentido tem o
seu segredo:

```
ida:    insight-worker ──▶ http://n8n:5678/webhook/creed/insights/v1   com o N8N_WEBHOOK_TOKEN
volta:  n8n ──▶ http://back:8000/api/v1/insights/callback              assinada com o N8N_CALLBACK_SECRET
```

As duas pontas são a rede interna do compose. O Caddy responde **404** ao callback vindo
de fora, e o N8N não passa por ele. O serviço `n8n` deste compose não muda por causa da
esteira.

### Variáveis

| Variável | Quem lê | Onde se define | Padrão, ou sem valor |
|---|---|---|---|
| `N8N_WEBHOOK_TOKEN` | worker | `.env` | vazio: o worker fica parado e não toca em nenhum pedido |
| `N8N_CALLBACK_SECRET` | back | `.env` | vazio: a rota de volta responde 401 a tudo |
| `N8N_WEBHOOK_URL` | worker | fixa no compose | `http://n8n:5678/webhook/creed/insights/v1` |
| `INSIGHT_MAX_IN_FLIGHT` | worker | `.env`, opcional | 5 — pedidos entregues ao N8N e ainda sem volta; é o único regulador contra a cota do Bedrock, que ainda não se conhece |
| `INSIGHT_MAX_ATTEMPTS` | worker **e** back | `.env`, opcional | 5 — uma linha só no `.env` vale para os dois, como deve: o callback também confere o limite |
| `INSIGHT_WORKER_INTERVAL_SECONDS` | worker | `.env`, opcional | 3 |
| `INSIGHT_WORKER_BATCH_SIZE` | worker | `.env`, opcional | 5 |
| `INSIGHT_DISPATCH_TIMEOUT_SECONDS` | worker | `.env`, opcional | 600 — passado esse tempo sem volta, o pedido é devolvido à fila |

Os padrões são os do `config.py` do creed-backend, que é a fonte (conferidos em
2026-11-15). Apagou uma `INSIGHT_*` do `.env`? Volta ao padrão. O token e o segredo
são **dois valores diferentes**, um por sentido: nenhum substitui o outro.

### Passos humanos

A IA não executa nenhum deles: são comandos na EC2, no Parameter Store e no editor do N8N.

Os dois valores têm que ser **iguais** no `.env` e no N8N: um token diferente faz o
webhook responder 401 à ida, e um segredo diferente faz o back responder 401 à volta.
Quem faz primeiro gera, e o outro lado copia. Os workflows da subtarefa 806 já estão
montados no N8N com os dois valores: copie-os de lá (passo 4) em vez de gerar outros.

1. **Ponha o segredo da volta no `.env`**, sem passar pelo histórico do terminal. Com o
   N8N já montado, cole o `valor` da linha `N8N_CALLBACK_SECRET` da data table
   `segredos-esteira`. O `read -rs` lê sem mostrar na tela:

   ```bash
   read -rs SEGREDO && echo "N8N_CALLBACK_SECRET=$SEGREDO" >> /opt/creed/.env && unset SEGREDO
   grep -c '^N8N_CALLBACK_SECRET=.\+' /opt/creed/.env   # 1
   ```

   Sem o N8N montado, gere com
   `echo "N8N_CALLBACK_SECRET=$(openssl rand -hex 32)" >> /opt/creed/.env` e leve o valor
   para o N8N no passo 4.

2. **Ponha o token da ida no `.env`, mas comentado.** Ele é o interruptor da esteira.
   Com o N8N já montado, cole o token da credencial Header Auth do webhook, **sem** o
   `Bearer ` do começo:

   ```bash
   read -rs TOKEN && echo "#N8N_WEBHOOK_TOKEN=$TOKEN" >> /opt/creed/.env && unset TOKEN
   grep -c '^#N8N_WEBHOOK_TOKEN=.\+' /opt/creed/.env    # 1
   ```

   Sem o N8N montado, gere com
   `echo "#N8N_WEBHOOK_TOKEN=$(openssl rand -hex 32)" >> /opt/creed/.env`.

   Sem o token, o worker avisa "esteira desligada" no log ao subir e não mexe em
   nenhum pedido: os `pending` esperam, sem gastar tentativa. É o estado certo até o
   workflow existir e estar ativo no N8N. Com o token no `.env` e o workflow ausente, o
   webhook responde 404, os pedidos gastam as 5 tentativas e viram `failed` — e não há
   "tentar de novo" (P-044).
3. **Parameter Store:** os dois valores em `/creed/prod/N8N_CALLBACK_SECRET` e
   `/creed/prod/N8N_WEBHOOK_TOKEN` (`SecureString`), como todo segredo novo (ver
   "Primeira vez").
4. **No N8N** (editor, `https://<IP>:5679`, projeto "Creed Educa"): os **mesmos
   valores**, que a subtarefa 806 já deixou lá. Nunca como literal num nó.
   - o token da ida fica na credencial **Header Auth** do nó "Recebe pedido do back",
     no workflow `insight-v1 entrada`, com o nome `Authorization` e o valor
     `Bearer <token>`. O back manda o prefixo `Bearer `, e o valor tem que ser igual;
   - o segredo da volta fica na data table **`segredos-esteira`**, na linha
     `nome = N8N_CALLBACK_SECRET`, coluna `valor`. Não é uma credencial porque o nó que
     assina (Crypto) recebe o segredo como texto, e uma expressão não lê o valor de uma
     credencial. Por isso o workflow `insight-v1 volta` não salva dados de execução: a
     saída do nó que lê a tabela tem o segredo. Detalhes em
     `creed-backend/docker/n8n/README.md`.
5. **Suba o worker e recrie o Caddy**, depois do deploy do back com as subtarefas 804 e
   805: o `BACK_TAG` do `.env` precisa ser de um commit que traz o worker. Numa imagem
   mais antiga o módulo não existe, e o container reinicia em loop.

   ```bash
   cd /opt/creed/creed-infrastructure && git pull
   cd ec2
   docker compose up -d                          # cria o worker e recria o back, com as variáveis novas
   docker compose up -d --force-recreate caddy   # o Caddyfile mudou (ver "Cuidados")
   ```

6. **Ligue a esteira**, só com o workflow **ativo** no N8N: descomente o token e
   recrie o worker. Para desligar de novo, comente a linha e rode o mesmo `up`.

   ```bash
   sed -i 's/^#N8N_WEBHOOK_TOKEN=/N8N_WEBHOOK_TOKEN=/' /opt/creed/.env
   cd /opt/creed/creed-infrastructure/ec2
   docker compose up -d insight-worker
   ```

7. **Confira.** Na EC2 e, o `curl`, de fora dela:

   ```bash
   docker compose ps insight-worker                          # Up
   docker compose logs insight-worker --tail 20
   curl -i -X POST https://<IP>/api/v1/insights/callback     # 404, sem corpo
   ```

   Um **401** no `curl` quer dizer que o Caddy ainda lê o `Caddyfile` antigo: recrie-o
   (ver "Cuidados").

### Como saber se está bem

O worker não tem `/health`. O sinal, como no ADR-0010, é o log e os pedidos que
envelhecem em `pending`. Pelo DBeaver, com o túnel descrito em "Conta na plataforma":

```sql
SELECT status, count(*), min(created_at) AS mais_antigo
FROM insights GROUP BY status;
```

Com a esteira **ligada**, um `PENDING` de horas atrás quer dizer que o worker ou o N8N
não está entregando: comece por `docker compose logs insight-worker`.

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
