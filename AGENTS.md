# AGENTS.md

## Projeto

Este repositório contém um jogo Tycoon desenvolvido para Roblox.

O código é escrito em Luau e sincronizado com Roblox Studio usando Rojo.

O objetivo deste arquivo é definir regras obrigatórias para qualquer agente de IA que modifique o projeto.

---

## Estrutura do projeto

A estrutura principal é:

src/
├── server/
├── client/
└── shared/

### src/server

Código executado exclusivamente no servidor.

Exemplos:
- economia
- dinheiro do jogador
- sistema de Tycoon
- compra de upgrades
- DataStore
- validação de compras
- criação de objetos controlados pelo servidor

### src/client

Código executado no cliente.

Exemplos:
- interface
- animações locais
- efeitos visuais
- feedback de botões
- câmera
- input do jogador

### src/shared

Código que pode ser utilizado por cliente e servidor.

Exemplos:
- configurações
- constantes
- tipos
- módulos compartilhados
- definições de upgrades

Nunca colocar lógica que precisa ser segura exclusivamente no cliente.

---

## Regras de segurança

Roblox utiliza uma arquitetura cliente-servidor.

O cliente nunca deve ser considerado confiável.

Toda ação importante deve ser validada pelo servidor.

Isso inclui especialmente:

- dinheiro
- compras
- upgrades
- recompensas
- rebirths
- desbloqueios
- produtos
- Game Passes
- salvamento de dados

Nunca aceitar valores financeiros enviados pelo cliente sem validação.

RemoteEvents e RemoteFunctions devem validar todos os dados recebidos pelo servidor.

O cliente pode solicitar uma ação, mas o servidor decide se ela é válida.

---

## Economia

O servidor deve ser a autoridade sobre a economia.

O cliente não pode decidir:

- quanto dinheiro possui;
- quanto uma compra custa;
- quanto uma máquina produz;
- se possui dinheiro suficiente;
- se um upgrade foi desbloqueado.

Evitar lógica econômica duplicada em vários scripts.

Valores configuráveis devem, quando apropriado, ficar em módulos de configuração.

---

## DataStore

Dados persistentes devem ser manipulados exclusivamente pelo servidor.

Nunca acessar DataStore pelo cliente.

Operações de salvamento devem possuir tratamento de erros.

Evitar salvar dados a cada pequena mudança.

Mudanças no formato dos dados devem considerar compatibilidade com dados antigos.

Nunca apagar ou substituir dados persistentes existentes sem necessidade explícita.

---

## RemoteEvents e RemoteFunctions

Não criar remotes desnecessariamente.

Todo remote recebido pelo servidor deve validar:

- tipo dos argumentos;
- valores permitidos;
- estado atual do jogador;
- permissões necessárias;
- possibilidade da ação solicitada.

Adicionar proteção contra spam/rate limiting quando uma ação puder ser abusada.

Nunca criar um remote que permita ao cliente definir diretamente dinheiro, upgrades ou outros dados importantes.

---

## Organização do código

Preferir ModuleScripts para sistemas reutilizáveis.

Evitar scripts extremamente grandes.

Cada módulo deve ter uma responsabilidade clara.

Evitar duplicação de código.

Usar nomes descritivos para funções e variáveis.

Evitar abreviações difíceis de entender.

Não criar dependências circulares entre módulos.

Não reorganizar grandes partes do projeto sem necessidade para a tarefa atual.

---

## Luau

Usar Luau moderno.

Quando for útil, utilizar tipagem para melhorar segurança e manutenção.

Preferir:

```lua
local function calculatePrice(basePrice: number, multiplier: number): number
	return basePrice * multiplier
end
