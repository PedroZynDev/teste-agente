# AGENTS.md

## Projeto

Este repositório contém um jogo Tycoon para Roblox, desenvolvido em Luau e sincronizado com Roblox Studio usando Rojo.

Este arquivo contém regras obrigatórias para qualquer agente de IA que trabalhe no projeto.

## Prioridades

Ao tomar decisões técnicas, seguir esta ordem de prioridade:

1. Segurança e integridade dos dados.
2. Funcionamento correto.
3. Compatibilidade com a arquitetura existente.
4. Legibilidade e manutenção.
5. Performance.
6. Conveniência de implementação.

Não implementar funcionalidades que não foram solicitadas.

## Estrutura do projeto

A estrutura principal é:

```text
src/
├── server/
├── client/
└── shared/
```

### src/server

Código executado exclusivamente pelo servidor.

Exemplos:

- economia;
- dinheiro;
- sistema de Tycoon;
- plots;
- compras;
- upgrades;
- DataStore;
- validações;
- recompensas.

### src/client

Código executado pelo cliente.

Exemplos:

- interface;
- câmera;
- input;
- animações locais;
- efeitos visuais;
- feedback ao jogador.

### src/shared

Código compartilhável entre servidor e cliente.

Exemplos:

- configurações;
- constantes;
- tipos;
- módulos compartilhados;
- definições de upgrades.

Código compartilhado não deve permitir que o cliente controle sistemas autoritativos.

## Arquitetura cliente-servidor

O servidor é autoritativo.

O cliente nunca deve ser considerado confiável.

Toda ação importante deve ser validada pelo servidor, especialmente:

- dinheiro;
- compras;
- preços;
- upgrades;
- recompensas;
- rebirths;
- desbloqueios;
- inventário;
- produtos;
- Game Passes;
- progresso persistente.

O cliente pode solicitar uma ação. O servidor decide se ela é permitida.

Nunca confiar em valores financeiros ou de progresso enviados pelo cliente.

## Economia

O servidor deve ser a única autoridade sobre a economia.

O cliente não pode decidir:

- quanto dinheiro possui;
- quanto dinheiro recebe;
- preço de uma compra;
- se possui saldo suficiente;
- produção de uma máquina;
- se um upgrade foi desbloqueado.

Evitar duplicar regras econômicas em vários scripts.

Valores configuráveis devem ficar em módulos de configuração quando apropriado.

## DataStore

DataStores devem ser acessados exclusivamente pelo servidor.

Operações persistentes devem possuir tratamento de erros.

Não salvar a cada pequena alteração sem necessidade.

Mudanças no formato dos dados devem considerar compatibilidade com dados já existentes.

Nunca apagar dados persistentes existentes sem solicitação explícita.

O agente não deve presumir que testes de DataStore foram realizados no Studio se não possuir acesso ao Studio.

## RemoteEvents e RemoteFunctions

Criar remotes somente quando necessários.

Todo dado recebido de um cliente deve ser validado pelo servidor.

Validar, conforme aplicável:

- tipo dos argumentos;
- valores e limites;
- estado atual do jogador;
- propriedade do Tycoon;
- saldo;
- permissões;
- distância física;
- cooldown;
- possibilidade real da ação.

Adicionar rate limiting quando uma ação puder ser abusada por spam.

Nunca criar um RemoteEvent ou RemoteFunction que permita ao cliente definir diretamente dinheiro, progresso ou upgrades.

## Organização do código

Cada módulo deve possuir responsabilidade clara.

Preferir ModuleScripts para sistemas reutilizáveis.

Evitar scripts excessivamente grandes.

Evitar duplicação de código.

Evitar dependências circulares.

Usar nomes descritivos.

Não reorganizar grandes partes do projeto para realizar uma tarefa pequena.

Não reescrever sistemas funcionais apenas por preferência de estilo.

Antes de criar um sistema, verificar se já existe código responsável pela mesma função.

## Luau

Usar Luau moderno e legível.

Utilizar tipagem quando ela melhorar segurança ou manutenção.

Exemplo:

```lua
local function calculatePrice(basePrice: number, multiplier: number): number
	return basePrice * multiplier
end
```

Preferir nomes claros e código simples a implementações excessivamente compactas.

Obter serviços Roblox usando `GetService`:

```lua
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
```

Evitar variáveis globais.

Não ignorar erros silenciosamente sem justificativa.

## Inicialização

Sistemas devem ter uma ordem de inicialização compreensível.

Evitar espalhar inicialização por muitos scripts sem necessidade.

À medida que o projeto crescer, preferir serviços e módulos com responsabilidades bem definidas.

## Interface

A interface representa o estado do jogo, mas não é a fonte oficial desse estado.

A interface nunca deve decidir resultados econômicos ou de progresso.

Alterações importantes devem ser confirmadas pelo servidor.

Quando possível, interfaces devem funcionar em diferentes resoluções e dispositivos.

## Performance

Evitar:

- loops infinitos sem espera;
- trabalho pesado a cada frame;
- chamadas remotas excessivas;
- criação excessiva de Instances;
- conexões de eventos desnecessárias;
- buscas repetidas pela hierarquia quando referências podem ser reutilizadas.

Recursos e conexões temporárias devem ser limpos quando deixarem de ser necessários.

Não realizar otimizações complexas prematuramente sem evidência de necessidade.

## Regras para alterações realizadas por agentes

Antes de modificar código:

1. Ler este `AGENTS.md` inteiro.
2. Ler os arquivos relacionados à tarefa.
3. Entender o comportamento existente.
4. Identificar quais arquivos realmente precisam mudar.
5. Fazer a menor alteração razoável que conclua a tarefa.
6. Preservar comportamentos que não fazem parte da solicitação.
7. Revisar possíveis impactos de segurança entre cliente e servidor.

Não remover código sem entender sua finalidade.

Não criar funcionalidades adicionais apenas porque parecem úteis.

Não adicionar dependências externas sem necessidade e justificativa.

Não modificar arquivos não relacionados à tarefa.

## Infraestrutura

Não modificar sem necessidade explícita:

- `AGENTS.md`;
- `default.project.json`;
- `rokit.toml`;
- `.gitignore`;
- workflows e configurações do GitHub.

Não alterar o mapeamento do Rojo para facilitar uma tarefa pequena.

Não adicionar arquivos gerados automaticamente pelo Roblox Studio ao Git sem necessidade.

## Git

Nunca alterar diretamente a branch `main`, salvo quando explicitamente solicitado pelo responsável pelo projeto.

Para tarefas de desenvolvimento, criar uma branch separada.

Preferir uma tarefa ou conjunto pequeno de alterações relacionadas por branch.

Mensagens de commit devem ser claras e descrever a intenção.

Exemplos:

```text
feat: add tycoon plot claiming
fix: validate upgrade purchases on server
refactor: separate economy configuration
docs: update datastore documentation
test: add economy integration test
```

Evitar mensagens genéricas como `changes`, `update`, `stuff` ou `fix`.

## Pull Requests

Quando o ambiente permitir, alterações do agente devem ser entregues por Pull Request para `main`.

O agente não deve fazer merge automaticamente.

O Pull Request deve informar:

- o que foi alterado;
- principais arquivos modificados;
- como testar no Roblox Studio;
- limitações ou riscos conhecidos.

O responsável humano decide se o PR será mesclado.

## Testes

Antes de considerar uma tarefa concluída:

- revisar sintaxe;
- revisar caminhos do Rojo;
- considerar diferenças entre servidor e cliente;
- revisar segurança;
- verificar possíveis estados inválidos;
- revisar apenas o diff final para garantir que não existam mudanças acidentais.

Quando a funcionalidade depender do Roblox Studio, fornecer instruções curtas para teste manual.

Nunca afirmar que algo foi testado no Roblox Studio sem realmente possuir acesso ao Studio.

Quando um teste não puder ser realizado pelo agente, declarar essa limitação claramente.

## Documentação

Comentários devem explicar decisões ou comportamentos não óbvios.

Evitar comentários que simplesmente repitam o código.

Mudanças arquiteturais relevantes devem atualizar a documentação correspondente.

Não criar documentação excessiva para funcionalidades triviais.

## Escopo do Tycoon

O projeto poderá futuramente possuir sistemas como:

- plots;
- reivindicação de Tycoon;
- dinheiro;
- produção;
- droppers;
- coletores;
- botões de compra;
- upgrades;
- rebirth;
- persistência;
- monetização;
- interface;
- efeitos visuais e sonoros.

Esta lista descreve possíveis sistemas, não tarefas atuais.

Não implementar antecipadamente sistemas dessa lista sem solicitação.

## Regra final

Segurança e integridade dos dados têm prioridade sobre conveniência.

O servidor é autoritativo para ações importantes.

Antes de criar uma solução nova, verificar se já existe um sistema responsável.

Manter alterações pequenas, compreensíveis, testáveis e compatíveis com a arquitetura existente.
