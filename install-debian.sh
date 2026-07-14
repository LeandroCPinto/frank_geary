#!/usr/bin/env bash
#
# Instala o FrankGeary (branch inbox-sections) no Debian 13 (trixie).
#
# Serve tanto para uma máquina nova quanto para uma que já tenha o repositório
# clonado — inclusive na branch errada, que é o caso quando o clone foi feito
# sem "-b inbox-sections".
#
#   bash install-debian.sh
#
set -euo pipefail

REPO_DIR="${REPO_DIR:-$HOME/src/frank_geary}"
FORK_URL="https://github.com/LeandroCPinto/frank_geary.git"
BRANCH="inbox-sections"

echo "==> 1/5 dependências"
sudo apt-get update
# traz o grosso das libs; o Debian 13 empacota o Geary 46, a mesma base do fork
sudo apt-get build-dep -y geary
sudo apt-get install -y meson ninja-build valac git
# estes três NÃO vêm pelo build-dep: o fork acompanha o upstream, um pouco à
# frente do que o pacote Debian usa
sudo apt-get install -y libgck-2-dev libgcr-4-dev libpeas-2-dev

echo "==> 2/5 código (branch $BRANCH)"
if [ -d "$REPO_DIR/.git" ]; then
    cd "$REPO_DIR"
    git remote get-url fork >/dev/null 2>&1 || git remote add fork "$FORK_URL"
    git fetch fork "$BRANCH"
    if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
        git checkout "$BRANCH"
        git merge --ff-only "fork/$BRANCH"
    else
        git checkout -b "$BRANCH" "fork/$BRANCH"
    fi
else
    mkdir -p "$(dirname "$REPO_DIR")"
    git clone -b "$BRANCH" "$FORK_URL" "$REPO_DIR"
    cd "$REPO_DIR"
fi
echo "    HEAD: $(git log --oneline -1)"

echo "==> 3/5 build"
[ -d build ] || meson setup build -Dprofile=release --prefix=/usr/local
meson compile -C build

echo "==> 4/5 instalação"
# instância única: um Geary rodando (inclusive o serviço do autostart) sequestra
# a abertura e você continuaria vendo a versão antiga
pkill -x geary || true
sudo meson install -C build
# obrigatório: o GSettings aborta o processo se faltar uma chave (inbox-sections)
sudo glib-compile-schemas /usr/local/share/glib-2.0/schemas
sudo ldconfig

echo "==> 5/5 pronto"
echo
echo "Abra o Geary pelo menu. As seções se configuram em Preferências >"
echo "Inbox Sections, ou importe as desta máquina com:"
echo
echo "    dconf dump /org/gnome/Geary/ > geary-config.ini   # origem"
echo "    dconf load /org/gnome/Geary/ < geary-config.ini   # destino"
