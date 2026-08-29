# OmaSeafile

Seafile na barra do Omarchy — **sem depender do cliente gráfico**.

![OmaSeafile](preview.png)

> *English:* Seafile bar widget for Omarchy. It talks to `seaf-daemon` over its
> own RPC socket, so it starts the daemon, logs into the server and adds
> libraries by itself — the Seafile desktop client is optional. UI is in
> Brazilian Portuguese.

## Instalação

```sh
omarchy plugin add https://github.com/FelipeMayerDev/omaseafile.git --enable
```

A única dependência é o binário `seaf-daemon`. Se ele não estiver na máquina,
o próprio painel oferece um botão que instala (`yay -S --needed seafile` no
Arch, que traz só o daemon e o `seaf-cli`, sem interface gráfica).

## O cliente gráfico é opcional

O OmaSeafile fala direto com o socket RPC do `seaf-daemon`
(`~/Seafile/.seafile-data/seafile.sock`), o mesmo que o `seaf-cli` usa. Por
isso ele não precisa do applet do Seafile rodando — nem instalado:

- sobe e derruba o `seaf-daemon` pela chave no painel;
- faz login no servidor e guarda o próprio token de API;
- adiciona e remove bibliotecas por conta própria.

Se você já usa o cliente gráfico, a conta configurada nele é aproveitada
automaticamente e nada muda.

## O que aparece

**Locais** — bibliotecas sincronizadas com estado ao vivo (sincronizada,
enviando, recebendo, indexando, pausada, erro), taxa de transferência, tamanho
em disco, downloads em andamento com porcentagem, pastas dentro de `~/Seafile`
que nenhuma biblioteca sincroniza, e erros por arquivo.

**Remotas** — bibliotecas que existem no servidor mas não sincronizam aqui,
com tamanho e data. O botão 󰇚 sincroniza na hora.

**Favoritos** — itens marcados com estrela no servidor. Se a biblioteca já
estiver sincronizada, o clique abre o arquivo local; senão, abre no navegador.

Notificações quando uma biblioteca começa a enviar ou receber, quando um
download termina, e quando algo falha. Ponto vermelho no ícone da barra em caso
de erro; o ícone pulsa durante uma transferência.

## Controles

- Chave no topo do painel: liga/desliga o `seaf-daemon`.
- 󰅖 numa biblioteca local: para de sincronizar (dois toques; os arquivos ficam).
- Clique numa linha: abre a pasta/arquivo, ou a biblioteca no servidor.
- Clique do meio no ícone da barra: atualiza na hora.

## Login

Servidor, e-mail e senha no painel. A senha só é trocada por um token de API
(`/api2/auth-token/`) e descartada; o token fica em
`~/.config/omarchy/omaseafile/account.json` com modo 0600.

Bibliotecas criptografadas ainda precisam do cliente gráfico, para a senha da
biblioteca.

## Ícone

`seafile.png` é o logo colorido, usado no painel. `seafile-mono.png` é a
máscara monocromática, tingida em tempo de execução com a cor do tema via
`MultiEffect` — o mesmo tratamento que o Tray do Omarchy dá a ícones
simbólicos. Na barra o ícone acompanha o tema; no painel continua colorido.

## Ajustes

`interval` (poll local, padrão 10s), `remoteInterval` (chamadas ao servidor,
só com o painel aberto) e `notifyTransfers`.

## CLI

`bin/seafile-status` funciona sozinho no terminal e só depende de `python3`:

```sh
seafile-status                 # estado local em json
seafile-status --sizes         # + tamanho em disco
seafile-status --remote        # conta, bibliotecas do servidor, favoritos
seafile-status --daemon-start | --daemon-stop
seafile-status --login         # {"server","user","password","otp"} no stdin
seafile-status --logout
seafile-status --sync <id> | --desync <id>
seafile-status --install-cmd   # comando que instala o seaf-daemon
seafile-status --selftest
```

## Licença

MIT.
