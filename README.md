# Retroute

Минимальный прокси-клиент в строке меню для **старых Маков на Intel — macOS 10.13 High Sierra и новее**. Внутри ядро [mihomo](https://github.com/MetaCubeX/mihomo), поверх — одно маленькое меню: подписка, список серверов, «Подключить».

Современные клиенты давно требуют macOS 11+ или Apple Silicon. Retroute сделан для тех, у кого MacBook 2012–2017 года и нет причин его выбрасывать.

*English version below.*

## Что умеет

- Подписки по URL (base64 или обычный список) и вставленные вручную ссылки.
- Протоколы: `vless` (включая REALITY и `xtls-rprx-vision`), `vmess`, `trojan`, `ss`, `hysteria2`.
- Транспорты: `tcp`, `ws`, `httpupgrade`, `grpc`, `h2`, `xhttp` (с настройками паддинга из `extra`).
- Панели с лимитом устройств (Remnawave `x-hwid-limit`): отправляет HWID, поэтому вместо заглушек приходят настоящие серверы.
- Включает системный прокси (HTTP, HTTPS, SOCKS) на `127.0.0.1:10808` и выключает его при отключении или выходе.
- Через прокси идут программы, которые используют системный прокси (браузеры и большинство приложений). Локальные сети — напрямую. TUN-режима нет.

Не поддерживается: `tuic`, `wireguard`, зашифрованные ссылки `happ://crypt…`.

## Установка

1. Скачайте `Retroute-x.y.z.zip` со страницы [Releases](../../releases) и распакуйте.
2. Перенесите `Retroute.app` в «Программы».
3. Первый запуск: **правый клик → «Открыть» → «Открыть»**. Приложение не подписано сертификатом Apple Developer, поэтому обычный двойной клик macOS заблокирует.
   Если macOS всё равно не даёт открыть:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Retroute.app
   ```
4. В строке меню появится **R ○**. Вставьте URL подписки или ссылки, выберите сервер и нажмите «Подключить» — значок станет **R ●**.

## Приватность

Retroute ничего не отправляет разработчику: аналитики и телеметрии нет. Сеть используется только для двух вещей:

- **Запрос подписки** уходит только на указанный вами URL. Вместе с ним передаются заголовки `x-hwid` (первые 8 байт SHA-256 от аппаратного UUID Мака, сам UUID не уходит), `x-device-os`, `x-ver-os` и `x-device-model`. Они нужны панелям с лимитом устройств.
- **Подписка запрашивается дважды:** с User-Agent `v2rayN` (ссылки) и `Happ` (JSON-форма, из которой берутся HTTP-заголовки транспорта). Второй запрос необязательный: если он не удался, используются просто ссылки.

Настройки лежат в `~/Library/Application Support/Retroute/` и в стандартных настройках macOS (`io.github.pinchedmon.retroute`).

## Переход с HappLite

Retroute — это HappLite 2.0 под новым именем. При первом запуске подписка, список серверов и выбранный сервер переносятся автоматически. Старый `HappLite.app` можно удалить.

## Сборка из исходников

Нужны Xcode Command Line Tools (`xcode-select --install`).

```sh
./build.sh
```

Скрипт компилирует `Sources/main.m` под x86_64 / macOS 10.13, скачивает mihomo из официального релиза MetaCubeX, сверяет SHA-256, собирает `build/Retroute.app` и `dist/Retroute-<версия>.zip`.

Проверка без запуска интерфейса:

```sh
build/Retroute.app/Contents/MacOS/Retroute --gen 'vless://…'   # печатает конфиг mihomo для ссылки
build/Retroute.app/Contents/MacOS/Retroute --fetch 'https://…' # печатает ссылки из подписки
build/Retroute.app/Contents/MacOS/Retroute --hwid              # HWID, версия macOS, модель
```

## Поддержать проект

Если Retroute вернул к жизни ваш старый Мак — можно [поддержать автора](https://widget.donatepay.ru/widgets/page/21d52433d9fb3f8cb58edf86617674cdbf21b21b05956b170322fd1f777c28a4?widget_id=7888887). Спасибо!

## Лицензия

[GPL-3.0-or-later](LICENSE). В приложение входит без изменений [mihomo](https://github.com/MetaCubeX/mihomo) (GPL-3.0); исходники ядра — в его репозитории, версия указана в `build.sh`.

Retroute — независимый проект и не связан с Happ, MetaCubeX или Apple. Используйте его в соответствии с законами вашей страны.

---

# Retroute (English)

A minimal menu-bar proxy client for **old Intel Macs running macOS 10.13 High Sierra or later**, built on the [mihomo](https://github.com/MetaCubeX/mihomo) core.

- Subscriptions by URL or pasted links: `vless` (REALITY, Vision), `vmess`, `trojan`, `ss`, `hysteria2` over `tcp` / `ws` / `httpupgrade` / `grpc` / `h2` / `xhttp`.
- Works with device-limited panels (Remnawave `x-hwid-limit`) by sending a hashed hardware ID.
- Sets the system HTTP/HTTPS/SOCKS proxy to `127.0.0.1:10808` and restores it on disconnect.

**Install:** download the zip from [Releases](../../releases), move `Retroute.app` to Applications, then right-click → Open on first launch (the app is ad-hoc signed, not notarized).

**Build:** `./build.sh` (needs Xcode Command Line Tools).

**Privacy:** no telemetry. Subscription requests go only to your URL and include `x-hwid` (truncated SHA-256 of the hardware UUID), OS version and Mac model.

**Support:** if Retroute keeps your old Mac useful, you can [support the author](https://widget.donatepay.ru/widgets/page/21d52433d9fb3f8cb58edf86617674cdbf21b21b05956b170322fd1f777c28a4?widget_id=7888887).

**License:** GPL-3.0-or-later. Bundles mihomo (GPL-3.0) unmodified. Not affiliated with Happ, MetaCubeX or Apple.
