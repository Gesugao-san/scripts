# tixati-channel-key.py

Выводит ключ канала Tixati из пароля, проверяет пары «пароль → хэш» и
разбирает ссылки-приглашения `dsc:`.

Схема: `base32_lower_nopad(clamp25519(SHA-256(utf8(пароль))))` — то же, что
делает кнопка **Hash** в окне Create New Channel (проверено на двух ключах).

## Формат данных

CSV с разделителем `;`, первая строка — заголовок на английском:

```
password;hash;channel;note;invite
iBwTOhLCvXTnrKBb;6djt7zrplpu4ywsyycsf4dde5txch2cumtezwu4idxvebw7cjzza;chan-ywlezb;main;dsc:jgdvwz6d…?dn=chan-ywlezb
```

- `password` — пароль (обязателен);
- `hash` — ключ канала (для `verify` обязателен, для `encode` может быть пустым);
- `channel` — имя канала; сравнивается с `dn=` из `invite`, если оба заданы;
- `note` — заметка, не проверяется;
- `invite` — ссылка-приглашение `dsc:HASHID?dn=ИМЯ`, необязательна.

`encode` переносит все колонки, кроме `hash`, в вывод как есть. Файлы
без колонки `invite` (4 колонки) по-прежнему подходят.

Строка заголовка распознаётся по `password` в первом поле (регистр не важен)
и может отсутствовать. Поля с `;` или кавычками берутся в кавычки по
правилам CSV. Пример: [`tixati-channel-key.example.csv`](tixati-channel-key.example.csv)
(случайные данные; Hash-ID в нём тоже случайные).

## Ссылки-приглашения и Hash-ID

Hash-ID в ссылке `dsc:` (он же «Hash-ID» в подсказке канала) зависит от
ключа **и** имени канала и детерминирован: тот же ключ и то же имя дают тот
же ID. Но формула неизвестна (Tixati закрыт), поэтому вычислить или
проверить Hash-ID по ключу скрипт не может. Он проверяет только формат
ссылки (52 символа base32) и что `dn=` совпадает с колонкой `channel` —
этого достаточно, чтобы поймать перепутанные строки.

## Как пользоваться

```
tixati-channel-key.py encode ApHfkCDJs8XX "ещё пароль"  # печатает password;hash
tixati-channel-key.py encode -f channels.csv            # заполняет колонку hash
tixati-channel-key.py verify ApHfkCDJs8XX 4chqjn3n5gj5rrf3yyjzipu52rf3hls362r27zjrxscmj5w42rka
tixati-channel-key.py verify -f channels.csv            # STATUS;password;hash
tixati-channel-key.py encode a b | tixati-channel-key.py verify
tixati-channel-key.py decode "dsc:HASHID?dn=ИМЯ"         # печатает hashid;name
tixati-channel-key.py decode -f links.txt                # по ссылке на строку
```

На Windows запускайте через `py`:

```powershell
py .\tixati-channel-key.py verify -f .\tixati-channel-key.example.csv
py .\tixati-channel-key.py encode -f channels.csv > channels.filled.csv
```

`verify` печатает по строке `STATUS;password;hash` на каждую запись, где
`STATUS` — `OK`, `MISMATCH` или `INVALID`; причина всего, что не `OK`, уходит
в stderr с номером строки. `MISMATCH` — хэш не подходит к паролю или имя в
`invite` не совпадает с `channel`.

`decode` раскодирует имя из `dn=` (кириллица, `%20` и т.п.) и приводит
Hash-ID к нижнему регистру; битые ссылки — в stderr. Ключ принимается в любом регистре, с паддингом `=` или без
него, и сравнивается за постоянное время.

В PowerShell нет перенаправления `<`, поэтому для файлов есть ключ `-f`.
Без `-f` и аргументов скрипт читает CSV из stdin.

Ввод всегда читается как UTF-8 (BOM игнорируется, CRLF допустим), вывод
пишется в UTF-8 независимо от кодовой страницы консоли. В Excel сохраняйте
как «CSV UTF-8»: обычный «CSV» в русской локали пишется в cp1251, и скрипт
откажется его читать.

Коды выхода: `0` — всё совпало, `1` — есть несовпадение, `2` — неверный ввод
(пустой пароль, нет хэша или он битый, битая ссылка, файл не найден или не
в UTF-8).

`channels.csv` и `pairs.txt` добавлены в `.gitignore`: в них могут быть
секретные пароли.

## Ограничения

- Схема подтверждена на ASCII-паролях; для не-ASCII паролей предполагается
  UTF-8.
- Hash-ID приглашения не проверяется по ключу (формула неизвестна).
- Ключ из короткого или распространённого пароля легко подобрать по словарю.
  Для настоящих каналов берите длинную случайную фразу.
- Нужен Python 3.10+, внешних зависимостей нет.
