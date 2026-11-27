# Implantação, backup e recuperação do Brando CRM

## Instalação auditada em 27/11/2026

O serviço Compose `deskcommcrm/crm` do EasyPanel executava `app`, `worker` e `scheduler` saudáveis. O endpoint público `/api/v1/health` respondeu HTTP 200. As três imagens vieram do GHCR do fork e carregavam a revisão `b7715c89af888115d554968ddb7f351cc7b7c0cd`, identificada pelo CRM como `b7715c8`. O checkout de suporte na VPS estava em `efed1d5745f87dfeaf3adbe8bc6165bc684a7a75` e continha ajustes locais do instalador. As imagens em execução são a referência para identificar a versão instalada.

| Componente | Estado observado |
| --- | --- |
| App, worker e scheduler | Imagens Linux AMD64 fixadas por digest, publicadas pelo workflow `publish-image.yml` |
| Banco | Supabase self-hosted, PostgreSQL 17.6, com o diretório de dados persistente na VPS |
| Anexos e mídia | Storage do Supabase em diretório persistente, WAHA com volumes separados de sessão e mídia |
| Fila e proxy | Redis com volume de dados, SRH, Caddy e Traefik do EasyPanel |
| Domínio e proteção | CRM em subdomínio do EasyPanel. A conexão Cloudflare consultada retornou zero zonas visíveis. |

Os digests atuais permitem preparar o retorno do app, worker e scheduler sem alterar o banco. Registre novamente os digests e a origem do Compose antes de cada liberação.

| Imagem em `ghcr.io/marlonbrandodeoliveira` | Digest observado |
| --- | --- |
| `deskcommcrm` | `sha256:b4f15a391a4a0dc14091320df66e9a8c6d8449d95a1fd20572cd06a0200e7b84` |
| `deskcomm-worker` | `sha256:c58451ac8363cdb6cb7545c0250681230a32a8d8a4f4907dc6603e13d2ddc054` |
| `deskcomm-scheduler` | `sha256:32b42a2cd96980727942312e15a95a8272403ccdb19020db896ce605af68202d` |

## Ativar a entrega contínua após autorização

1. No GitHub, desative o workflow legado `sync-deskcomm-upstream.yml` em Actions. Ele foi encontrado ativo e pode mesclar releases diretamente em `main`. Verifique a ausência de uma execução em andamento. Em `dev`, a proposta retira o workflow legado.
2. Configure a proteção de `main` para exigir pull request e checks. Restrinja o ambiente GitHub `production` a `main` e configure aprovação obrigatória pelo responsável. Preserve `upstream` como espelho. Garanta que nenhum webhook, agendamento ou auto-deploy aplicado ao CRM publique sem essa aprovação.
3. No ambiente `production`, configure as variáveis `PROD_SSH_HOST` e `PROD_SSH_USER` e os secrets `PROD_SSH_KEY` e `PROD_SSH_KNOWN_HOSTS`. Use uma credencial de implantação dedicada, confirme a chave de host fora do workflow e restrinja o acesso aos operadores de produção. O usuário executa o script com acesso ao Docker deste serviço. Provisione o token do EasyPanel para esse usuário em `~/.local/state/deskcomm-deploy/panel.token`, com permissões `0700` no diretório e `0600` no arquivo. O token só é enviado à API local do painel.
4. Valide em ambiente isolado com Compose equivalente, token de teste, dados sintéticos e as mesmas versões de Docker e PostgreSQL. Confirme que o serviço usa fonte inline em JSON e que o token pode ler, gravar a fonte e solicitar implantação do Compose. Teste backup, restauração, rollback e o fluxo de aprovação antes da primeira ativação.

O contrato aproveita o serviço existente do EasyPanel. GitHub Actions publica as imagens de `main` em GHCR. O workflow manual `Implantar Brando CRM` usa o SHA aprovado para validar e fixar os três digests no mesmo Compose, preservar a origem e chamar o EasyPanel. As variáveis públicas em tempo de execução e os segredos de produção continuam no painel e no host.

## Antes de cada publicação

1. Confirme PR e checks aprovados, SHA no topo de `main`, sucesso de `publish-image.yml` para esse mesmo SHA e janela de operação quando houver mudança de schema. Revise as notas e confirme a compatibilidade da versão anterior com o novo schema, se aplicável.
2. Registre o SHA implantado, os três digests, a fonte Compose e as configurações do EasyPanel. Guarde-os criptografados fora do Git. Faça o backup completo descrito abaixo e verifique uma restauração isolada. Valide e registre o candidato no staging.
3. Obtenha aprovação explícita para o SHA. Dispare `Implantar Brando CRM` em `main` com o SHA completo e aprove o job `production`. O script rejeita um SHA diferente do topo de `main`, exige publicação bem-sucedida e verifica as três revisões OCI antes de trocar as imagens.
4. O script guarda a fonte anterior e um dump do PostgreSQL. Com mudança no `baseline.sql`, ele para app, worker e scheduler para aplicar o baseline em transação. Coordene a suspensão de outros escritores e integrações durante essa janela. Durante o backup e a validação do candidato, confira o espaço para as imagens e os arquivos temporários.
5. Após o deploy, confira os três containers saudáveis no mesmo SHA, a versão em `/api/v1/health`, login e leitura de contatos, conversa e mídia. Verifique scheduler, worker e integrações com uma conta de teste autorizada. Registre horário, SHA, digests e resultado.

O modo `--check SHA_COMPLETO_DE_MAIN` valida o candidato sem gravar a fonte do EasyPanel ou aplicar schema. Ele baixa imagens e guarda uma cópia do Compose no diretório privado. Execute-o primeiro em staging com serviços e estado isolados.

## Backup completo

- Gere um dump lógico PostgreSQL em formato custom com `pg_dump -Fc`, incluindo os schemas de aplicação, Auth e Storage, e faça um export seguro dos papéis globais necessários à recuperação. Na instalação auditada, `supabase_admin` conecta ao banco `postgres` dentro de `deskcommcrm_crm-supabase-db-1`. Use a mesma major das ferramentas de restauração.
- Capture o Storage do Supabase, os volumes WAHA de sessões e mídia, o Redis se houver dados persistentes de fila e os arquivos necessários de configuração do Caddy e do Supabase. Registre a correspondência dos mounts. Coordene uma visão consistente do banco e dos volumes com uma janela de escrita controlada ou snapshot consistente. O diretório PostgreSQL ativo exige um mecanismo de backup físico compatível ou dump lógico.
- Exporte sob controle de acesso a fonte e as configurações do EasyPanel, chaves de criptografia da aplicação, Auth e integrações, inventário de domínios e runtime, além dos digests anteriores. A restauração das configurações precisa preservar a capacidade de decifrar os dados existentes.
- Gere checksums e retenha uma cópia criptografada fora da VPS com acesso restrito. Valide legibilidade e checksums, use `pg_restore --list` e restaure em outra instância com rede e integrações isoladas. Faça uma verificação de contagens, login, amostras de anexos e isolamento de organizações. Registre data, tamanho, cobertura e resultado do ensaio. Agende backups conforme a frequência de perda de dados aceitável para a operação.

Para preparar os artefatos do banco durante uma janela aprovada, rode em Bash na VPS com acesso ao Docker. Trate o dump e os papéis como segredos. Complete o backup com os volumes e configurações acima.

```bash
set -euo pipefail
umask 077
backup_dir=$(mktemp -d "$HOME/deskcomm-backup.XXXXXXXX")
db=deskcommcrm_crm-supabase-db-1
docker exec "$db" pg_dump -U supabase_admin -d postgres -Fc > "$backup_dir/db.dump"
docker exec "$db" pg_dumpall -U postgres --roles-only > "$backup_dir/roles.sql"
docker exec -i "$db" pg_restore --list < "$backup_dir/db.dump" > "$backup_dir/db.list"
(cd "$backup_dir" && sha256sum db.dump roles.sql db.list > SHA256SUMS)
printf '%s\n' "$backup_dir"
```

## Rollback e recuperação

1. Diante de falha, pause a publicação e confirme a revisão e o estado do banco. Guarde o diretório privado da tentativa, com a fonte anterior e o dump. A presença de `pending` bloqueia uma nova tentativa até o operador diagnosticar e reconciliar a configuração.
2. Se o schema está compatível, restaure a fonte Compose anterior no mesmo serviço com os três digests registrados. Preserve as montagens, rede, dados e variáveis. Solicite deploy pelo EasyPanel após aprovação e confira os mesmos testes de saúde. Se a falha ocorreu antes de confirmar uma alteração do schema, determine no banco se a transação foi efetivada antes de subir a versão anterior.
3. Se o schema impede o retorno do código, recupere o backup em uma instância isolada. Verifique o banco, as chaves, Storage, WAHA e as gravações feitas desde o backup. Defina a reconciliação e a janela antes de solicitar qualquer mudança de banco ou redirecionamento na produção. Registre o resultado antes de limpar o `pending` e encerrar a ocorrência.

## Domínio e Cloudflare

Após informar a zona e autorizar a mudança, inventarie DNS, certificado de origem e rotas atuais. Crie ou ajuste apenas o subdomínio aprovado. Preserve o endereço do EasyPanel durante a validação. Com certificado de origem válido para o hostname, habilite o proxy e SSL/TLS **Full (strict)**, conforme o escopo da zona. Use bypass de cache para o CRM autenticado e APIs dinâmicas, e valide autenticação, tempo real, retorno OAuth, armazenamento, webhooks e envio de teste antes do corte. Preserve os demais registros da zona e as rotas internas. Se o corte falhar, restaure o apontamento e a configuração anteriores conforme o inventário.

- [Compose no EasyPanel](https://easypanel.io/docs/services/compose)
- [Ambientes e aprovação no GitHub Actions](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments)
- [TLS Full (strict) na Cloudflare](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/full-strict/)
