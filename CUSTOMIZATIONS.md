# Personalizações do Brando CRM

| Data | Mudança | Arquivos e evidência |
| --- | --- | --- |
| 27/11/2026 | Automação anterior do fork, encontrada na versão em produção | `b7715c89a` adicionou o sincronizador de `main` e um script de atualização do Compose no EasyPanel. A VPS executava app, worker e scheduler desse SHA. |
| 27/11/2026 | Fluxo Brando de desenvolvimento, atualização e operação | `AGENTS.md`, `README.md`, `UPDATE_GUIDE.md` e `DEPLOYMENT.md`. O upstream continua disponível no histórico e na branch `upstream`. |
| 27/11/2026 | Preparação de deploy manual por SHA aprovado | `deploy-brando.yml` registra a aprovação no GitHub. `ops/easypanel/deploy-published-deskcomm.sh` aplica a revisão aprovada pela API local do EasyPanel. As credenciais ficam com o operador e na VPS. Veja a validação e a ativação em `DEPLOYMENT.md`. |

## Onde estender

- Use as configurações nativas do CRM para marca, permissões e integrações quando cobrirem a necessidade. A marca em tela pode ser tratada separadamente na configuração de aparência.
- Agrupe funcionalidades novas por módulo, próximos aos pontos de extensão existentes. Use adaptadores para sistemas externos. Mantenha alterações no núcleo limitadas aos pontos de integração de cada módulo.
- Para mudanças de dados, siga a convenção do DeskcommCRM para migration e atualização do `supabase/baseline.sql`. Cubra isolamento por organização, autorização, auditoria e idempotência quando aplicáveis.

Cada mudança deve registrar data, objetivo, módulo e arquivos, PR ou SHA, testes, impacto operacional e como reverter. Inclua configurações relevantes por nome, mantendo valores de produção fora do Git.
