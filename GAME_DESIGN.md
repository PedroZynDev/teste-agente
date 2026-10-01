# Game Design — Mining Tycoon

## Visão geral

O jogo é um Tycoon de mineração para Roblox.

Cada jogador controla sua própria mina e evolui sua operação para produzir minérios progressivamente mais valiosos.

O foco do jogo é:

- produzir minérios;
- vender minérios;
- ganhar dinheiro;
- melhorar a mina;
- desbloquear minérios melhores;
- alcançar requisitos de rebirth;
- realizar rebirth;
- ganhar Rubis;
- utilizar Rubis em progressão especial.

## Servidor

Máximo planejado:

6 jogadores por servidor.

O mapa deve possuir 6 plots de Tycoon.

Cada jogador pode controlar no máximo um plot por vez.

## Loop principal

O ciclo principal é:

1. O jogador reivindica uma mina.
2. Máquinas produzem minérios.
3. Os minérios caem em uma esteira.
4. A esteira transporta os minérios.
5. Os minérios chegam a um coletor.
6. O coletor converte os minérios em dinheiro.
7. O jogador compra melhorias.
8. Novas máquinas e níveis produzem minérios melhores.
9. A produção e o valor dos minérios aumentam.
10. O jogador eventualmente atinge os requisitos para realizar um rebirth.

## Dinheiro

Dinheiro é a moeda principal da progressão normal.

É utilizado para comprar:

- máquinas;
- novos droppers;
- melhorias;
- níveis da mina;
- outras expansões normais.

O servidor é autoritativo sobre todo o dinheiro.

O cliente nunca decide saldo, preço ou recompensa.

O dinheiro é reiniciado de acordo com as regras do sistema de rebirth.

## Minérios

Minérios são objetos físicos produzidos pelas máquinas da mina.

Eles caem sobre uma esteira e são transportados até um coletor.

Cada tipo/nível de minério possui um valor.

Minérios de níveis mais avançados possuem maior valor.

Inicialmente, modelos simples podem ser utilizados como placeholders.

Posteriormente, os minérios poderão receber modelos, materiais, cores, partículas e outros efeitos visuais próprios.

## Progressão dos minérios

A progressão deve permitir que novos níveis introduzam minérios melhores.

Uma progressão possível é:

- Pedra
- Carvão
- Cobre
- Ferro
- Prata
- Ouro
- Diamante
- Esmeralda
- minérios especiais/fantásticos

Essa lista ainda não é definitiva.

Valores e balanceamento devem ficar centralizados em configuração, em vez de espalhados pelo código.

## Esteiras

Droppers/máquinas produzem minérios acima ou próximos de uma esteira.

A esteira transporta os minérios até o coletor.

O sistema deve ser projetado considerando performance, pois vários jogadores poderão produzir minérios simultaneamente.

Limites de objetos e mecanismos de limpeza poderão ser implementados conforme necessário.

## Coletor

O coletor recebe os minérios pertencentes à mina.

Quando um minério válido chega ao coletor:

1. o servidor identifica o minério;
2. valida sua origem/propriedade;
3. determina seu valor;
4. adiciona dinheiro ao proprietário;
5. remove o objeto coletado.

O cliente não pode informar ao servidor quanto um minério vale.

## Upgrades

Dinheiro poderá comprar melhorias como:

- novos droppers;
- maior velocidade de produção;
- minérios melhores;
- novos níveis;
- melhorias da esteira;
- expansões da mina.

A lista definitiva será definida durante o desenvolvimento.

## Rebirth

Rebirth é uma camada de progressão de longo prazo.

Ao alcançar requisitos específicos, o jogador poderá realizar um rebirth.

Um rebirth deve reiniciar parte significativa da progressão normal, incluindo o dinheiro e a evolução normal da mina.

Em troca, o jogador recebe Rubis.

As regras exatas de custo, quantidade de Rubis e progressão serão balanceadas posteriormente.

## Rubis

Rubis são uma moeda persistente de progressão especial.

Visualmente, são representados pelo conceito de um minério/cristal roxo.

Rubis são obtidos principalmente através de rebirth.

Rubis NÃO devem ser apagados ao realizar outro rebirth.

Eles poderão ser usados em uma Loja de Rubis.

## Loja de Rubis

A Loja de Rubis poderá oferecer elementos especiais, por exemplo:

- bônus permanentes;
- melhorias especiais;
- cosméticos;
- efeitos visuais;
- melhorias de qualidade de vida.

A lista definitiva será definida posteriormente.

O nome "Loja de Rubis" é preferível a "Loja Premium" para evitar confusão entre Rubis e compras realizadas com Robux.

## Robux

Rubis e Robux são conceitos diferentes.

Nunca tratar Rubis como se fossem Robux.

Caso monetização com Robux seja adicionada futuramente, ela deverá ser implementada como sistema separado.

## Persistência

No futuro, o DataStore deverá salvar pelo menos:

- progressão relevante;
- Rubis;
- número de rebirths;
- upgrades persistentes;
- compras permanentes.

O formato definitivo dos dados será decidido quando o sistema de persistência for implementado.

## Autoridade do servidor

Sistemas econômicos são autoritativos no servidor.

Isso inclui:

- dinheiro;
- Rubis;
- valor dos minérios;
- compras;
- upgrades;
- rebirth;
- propriedade das minas;
- recompensas.

O cliente apenas exibe informações e envia solicitações.

## Direção de desenvolvimento

Implementar o jogo incrementalmente.

Não criar todos os sistemas antecipadamente.

Prioridade atual:

1. sistema de plots;
2. dinheiro;
3. primeiro dropper;
4. esteira e coletor;
5. primeira compra;
6. persistência básica;
7. interface;
8. progressão;
9. rebirth;
10. Rubis.

Sistemas posteriores não devem ser implementados até serem solicitados.
