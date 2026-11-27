# Incorporar atualizações oficiais

## 1. Atualizar o espelho

Com o checkout limpo, confirme que `origin` é o fork e `upstream` é `melgarafael/DeskcommCRM`. O espelho acompanha a branch oficial por avanço direto. Use as [releases oficiais](https://github.com/melgarafael/DeskcommCRM/releases) para escolher a versão candidata.

```bash
git remote -v
git fetch --no-tags origin main dev upstream
git fetch --no-tags upstream main
git switch upstream
git merge --ff-only upstream/main
git push origin upstream
```

Se o espelho divergir do oficial, investigue a origem antes de atualizar a referência. Preserve alterações próprias em `dev`.

## 2. Integrar em uma branch a partir de `dev`

Substitua `vX.Y.Z` por uma release revisada. Leia as notas das versões desde a base já incorporada, incluindo avisos de configuração, imagens, schema e integrações.

```bash
release=vX.Y.Z
git fetch --no-tags upstream "refs/tags/$release"
official_commit=$(git rev-parse 'FETCH_HEAD^{commit}')
git merge-base --is-ancestor "$official_commit" upstream/main || exit 1
git switch dev
git merge --ff-only origin/dev
git switch -c "update/deskcomm-$release"
git merge --no-ff "$official_commit"
```

Em conflito, use `git status` e `git diff --name-only --diff-filter=U`. Revise em especial a documentação Brando, as extensões existentes, o Compose, as variáveis e o schema. Preserve as duas intenções quando forem compatíveis. Use `git merge --abort` se precisar revisar a integração do início. Confira `git diff --check` e a relação dos commits ao concluir.

## 3. Validar e promover

1. Em ambiente isolado, instale pelo lockfile e rode `pnpm gov:verify`, `pnpm test:shell`, `pnpm test:db`, `pnpm test:db:update` e `pnpm build`. Execute o Playwright com Supabase local semeado, conforme o [setup oficial](docs/SETUP.md). Valide as imagens e o Compose no formato do ambiente de teste.
2. Com dados fictícios, teste login, permissões entre organizações, contatos, conversa e anexos, processamento do worker e scheduler e, quando houver mudanças, webhooks e WhatsApp de teste. Ensaios com cópia aprovada de produção exigem ambiente isolado, acesso restrito e integrações externas bloqueadas.
3. Registre versão oficial e SHA, conflitos, alterações próprias, testes, efeitos de schema e procedimento de retorno em [CUSTOMIZATIONS.md](CUSTOMIZATIONS.md) e no PR. Abra o PR de atualização para `dev`. Use merge que preserve os commits oficiais no histórico.
4. Depois da validação em `dev`, abra um PR para `main`, aguarde os checks e a autorização de promoção. Aplique o [procedimento de implantação](DEPLOYMENT.md) com nova autorização para o SHA que será instalado.

O botão de atualização oficial dentro do CRM, os jobs de sincronização direta e as tags móveis ficam fora do procedimento de release do Brando.
