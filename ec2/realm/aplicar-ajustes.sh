#!/usr/bin/env bash
# Aplica no realm `creed` de produção os ajustes do realm-creed.json (CREED-23.8, D11).
#
#   ./realm/aplicar-ajustes.sh <seu admin do realm master>
#
# O compose sobe o Keycloak com `start --import-realm`, que só importa um realm que
# ainda não existe. O realm de produção nasceu antes do SMTP, do idioma, da política
# de senha, do redirect e do perfil, e mudar o arquivo não chega a ele. O
# `kc.sh import --override` resolveria, mas apaga e recria o realm, com os usuários.
#
# Na ordem:
#   1. lê os blocos do realm-creed.json do clone do creed-backend, o mesmo arquivo
#      que o compose monta no Keycloak: uma fonte só;
#   2. troca os ${VAR} pelos valores que o compose entrega ao Keycloak, que vêm do
#      .env desta pasta (na EC2, o /opt/creed/.env);
#   3. aplica com o kcadm.sh de dentro do container: atributos do realm, redirect do
#      client creed-backend e perfil;
#   4. mostra como ficou.
#
# Rodar de novo aplica os mesmos valores: não muda nada nem falha. Roda como
# ec2-user, de dentro da EC2, e precisa do jq 1.6 ou mais novo, o primeiro com o
# walk (sudo dnf install -y jq).
set -euo pipefail

ADMIN="${1:?uso: realm/aplicar-ajustes.sh <seu admin do realm master>}"
cd "$(dirname "$0")/.."
# O mesmo caminho do volume do keycloak no docker-compose.yml.
BACKEND_CLONE=../../creed-backend
REALM_FILE=$BACKEND_CLONE/docker/keycloak/realm-creed.json

command -v jq >/dev/null || { echo "!!! falta o jq: sudo dnf install -y jq" >&2; exit 1; }
[[ -r "$REALM_FILE" ]] || { echo "!!! não achei o $REALM_FILE" >&2; exit 1; }

# Tudo pelo container: o kcadm.sh vem na imagem do Keycloak e fala com a porta 8080
# pela própria máquina, sem passar pelo Caddy.
kcadm() {
  docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh "$@"
}

echo "==> 1/4 lendo o realm-creed.json e os valores do compose"
# Um realm-creed.json de antes da CREED-23.8 não tem os blocos abaixo. O jq os leria
# como null, o Keycloak ignora atributo null no update, e o script terminaria em
# "pronto" com o realm como estava. Bloco ausente para o script aqui. Bloco vazio,
# como um redirect [], não é ausente: é o arquivo dizendo "nenhum".
FALTANDO=$(jq -r '
  [.clients[]? | select(.clientId == "creed-backend")][0] as $client
  | {
      internationalizationEnabled, supportedLocales, defaultLocale, passwordPolicy,
      smtpServer,
      "client creed-backend": $client,
      "redirectUris do client creed-backend": $client.redirectUris,
      "webOrigins do client creed-backend": $client.webOrigins,
      "perfil (users/profile)": .components["org.keycloak.userprofile.UserProfileProvider"][0]
                                  .config["kc.user.profile.config"][0]
    }
  | to_entries | map(select(.value == null) | .key) | join(", ")' "$REALM_FILE")
if [[ -n "$FALTANDO" ]]; then
  echo "!!! o realm-creed.json não tem: $FALTANDO" >&2
  echo "    Lido de $(realpath "$REALM_FILE")." >&2
  echo "    O clone do creed-backend está num commit sem a CREED-23.8? Confira:" >&2
  echo "    git -C $(realpath "$BACKEND_CLONE") log -1 --format='%h %ad %s' -- docker/keycloak/realm-creed.json" >&2
  exit 1
fi

# Os valores vêm do compose, e não do .env direto, para o "de-para" ficar num lugar
# só: lá a FRONTEND_URL vira CREED_FRONTEND_URL, e SMTP_AUTH, SMTP_STARTTLS e
# SMTP_SSL são fixos. Só entram as variáveis que o arquivo usa, as SMTP_* e a
# CREED_FRONTEND_URL: o resto do environment do Keycloak (senha do banco, segredo
# do client, admin temporário) o script não precisa ver. O `config` escreve o "$"
# literal como "$$"; aqui ele volta a ser "$". Fica numa variável do shell, nunca em
# arquivo nem na linha de comando de um processo, porque tem a senha do SMTP. Pelo
# mesmo motivo, nada de `bash -x` aqui: o rastro imprime este JSON, com a senha.
KEYCLOAK_ENV=$(docker compose config --format json | jq '
  .services.keycloak.environment
  | with_entries(select(.key | startswith("SMTP_") or . == "CREED_FRONTEND_URL"))
  | map_values(if type == "string" then gsub("\\$\\$"; "$") else . end)')

# Vazia, o redirect do client vira "/*", relativo ao próprio Keycloak. Com barra no
# fim, o back monta "...//login".
FRONTEND_URL=$(printf '%s' "$KEYCLOAK_ENV" | jq -r '.CREED_FRONTEND_URL // ""')
if [[ "$FRONTEND_URL" != https://* || "$FRONTEND_URL" == */ ]]; then
  echo "!!! FRONTEND_URL no .env precisa ser https://... sem barra no fim (está '$FRONTEND_URL')" >&2
  exit 1
fi

# Os três blocos, já com os valores. A troca de ${VAR} passa só pelos atributos e
# pelo redirect: o texto do perfil tem ${username}, ${email}, ${firstName} e
# ${lastName}, que são chaves de mensagem do Keycloak, e vai como está no arquivo.
# Variável vazia para o script aqui, antes de pedir a senha do admin.
# O webOrigins vai junto com o redirect porque, sem ele, o Keycloak deriva do
# redirect a origem do front e a grava, e o arquivo diz que não há nenhuma.
AJUSTES=$(printf '%s' "$KEYCLOAK_ENV" | jq --slurpfile realm "$REALM_FILE" '
  . as $env
  | def trocar_variaveis:
      walk(if type == "string" then
             gsub("\\$\\{(?<nome>[A-Z_]+)\\}";
                  .nome as $nome
                  | ($env[$nome] // "")
                  | if . == "" then error("\($nome) está vazia: preencha o .env") else . end)
           else . end);
  $realm[0]
  | {
      atributos: ({internationalizationEnabled, supportedLocales, defaultLocale,
                   passwordPolicy, smtpServer} | trocar_variaveis),
      redirect: (.clients[] | select(.clientId == "creed-backend")
                 | {redirectUris, webOrigins} | trocar_variaveis),
      perfil: .components["org.keycloak.userprofile.UserProfileProvider"][0]
                .config["kc.user.profile.config"][0]
    }')

echo "==> 2/4 entrando no Keycloak como $ADMIN"
# Sem -T: o kcadm pede a senha no terminal. A sessão fica guardada no container, em
# ~/.keycloak/kcadm.config, com o token do seu admin do master, e os comandos
# seguintes a usam. O arquivo só some quando o container é recriado (README).
docker compose exec keycloak /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080/auth --realm master --user "$ADMIN"

CLIENT_ID=$(kcadm get clients -r creed -q clientId=creed-backend --fields id --format csv --noquotes)
[[ -n "$CLIENT_ID" ]] || { echo "!!! o client creed-backend não existe no realm creed" >&2; exit 1; }

echo "==> 3/4 aplicando no realm creed"
# Tudo pela entrada padrão (-f -): a senha do SMTP nunca vai na linha de comando.
printf '%s' "$AJUSTES" | jq '.atributos' | kcadm update realms/creed -f -
printf '%s' "$AJUSTES" | jq '.redirect' | kcadm update "clients/$CLIENT_ID" -r creed -f -
printf '%s' "$AJUSTES" | jq -r '.perfil' | kcadm update users/profile -r creed -f -

echo "==> 4/4 como ficou (a senha do SMTP aparece mascarada)"
# Sem o (*), o --fields mostra o smtpServer vazio, mesmo preenchido.
kcadm get realms/creed \
  --fields 'smtpServer(*),internationalizationEnabled,supportedLocales,defaultLocale,passwordPolicy'
kcadm get "clients/$CLIENT_ID" -r creed --fields clientId,redirectUris,webOrigins
kcadm get users/profile -r creed | jq '.attributes[] | select(.name == "email") | {name, permissions}'
echo "==> pronto. Confira o Test connection na aba Email do realm creed (README)."
