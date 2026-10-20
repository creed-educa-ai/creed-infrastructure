#!/usr/bin/env bash
# Deploy do back na EC2 (CREED-285).
#
#   ./deploy.sh <commit>
#
# Quem chama é o workflow do creed-backend, pelo Session Manager, depois de publicar
# a imagem ghcr.io/creed-educa-ai/creed-backend:<commit>. Roda como ec2-user (dono
# deste clone e do grupo docker). À mão, de dentro da EC2, funciona igual.
#
# A ordem é o princípio inegociável #2: a migration roda num container descartável
# ANTES de recriar o back. Se ela falhar, o script para aqui e o back antigo segue
# no ar, com o banco como estava.
#
# Este script não faz `git pull` do creed-infrastructure: mudança no compose de
# produção é aplicada à mão, com alguém olhando (ver README).
set -euo pipefail

COMMIT="${1:?uso: deploy.sh <commit da imagem>}"
ENV_FILE="${ENV_FILE:-/opt/creed/.env}"
cd "$(dirname "$0")"

# Até o fim, o compose usa a imagem nova só nestes comandos. O .env só muda no
# final, quando ela já estiver de pé.
export BACK_TAG="$COMMIT"

echo "==> 1/4 baixando a imagem $COMMIT"
docker compose pull back

echo "==> 2/4 migration (container descartável da imagem nova)"
docker compose run --rm --no-deps back alembic upgrade head

echo "==> 3/4 recriando o back"
docker compose up -d --no-deps back

echo "==> 4/4 esperando o back responder"
for _ in $(seq 30); do
  if docker compose exec -T back python -c \
      "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')" \
      >/dev/null 2>&1; then
    # Só agora a versão nova vira a oficial: qualquer `docker compose up` futuro,
    # inclusive depois de reiniciar a EC2, sobe esta imagem.
    sed -i '/^BACK_TAG=/d' "$ENV_FILE"
    echo "BACK_TAG=$COMMIT" >> "$ENV_FILE"
    echo "==> back no ar: $COMMIT"
    exit 0
  fi
  sleep 2
done

# A migration já rodou, então voltar à imagem anterior sozinho não é seguro: ela
# pode não conhecer o banco novo. Quem decide é uma pessoa, olhando o log.
echo "!!! o back não respondeu em 60 s. Últimas linhas do log:" >&2
docker compose logs back --tail 40 --no-color >&2
exit 1
