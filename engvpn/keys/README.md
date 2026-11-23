# EngVPN Minisign keys

Подпись пакетов feed EngVPN (Ed25519 / [minisign](https://jedisct1.github.io/minisign/)).

## Публичный ключ

Файл `engvpn.minisign.pub` входит в репозиторий и копируется в пакет (`share/engvpn/engvpn.minisign.pub`).

```
untrusted comment: minisign public key 2B2E9ADA0F3597D4
RWTUlzUP2pouK7/33m+ECsr4VEhXdtMoJQmUtXzlGzvPe8gNKObfeaBG
```

Проверка вручную:

```sh
minisign -Vm engvpn_0.4.0_merlin-aarch64.tar.gz -p engvpn/keys/engvpn.minisign.pub
```

Или через Node (на роутере с Entware):

```sh
node share/engvpn/verify-minisign.mjs package.tar.gz package.tar.gz.minisig share/engvpn/engvpn.minisign.pub
```

## Секретный ключ

`engvpn.minisign.key` **не** коммитится (см. `.gitignore`). Храните у maintainer’а / в CI secrets.

Подпись при публикации:

```sh
minisign -Sm dist/engvpn_${VERSION}_merlin-aarch64.tar.gz -s engvpn/keys/engvpn.minisign.key
```

`publish-release.sh --push` подписывает все arch-пакеты, если секретный ключ доступен как `ENGVPN_MINISIGN_KEY` или `engvpn/keys/engvpn.minisign.key`.

## Ротация

1. `minisign -G -p engvpn/keys/engvpn.minisign.pub -s engvpn/keys/engvpn.minisign.key`
2. Обновить этот README и встроенный pubkey в пакете.
3. Переподписать релизы; старые `.minisig` перестанут проверяться новым ключом.
