# tixati-channel-key.py

Выводит ключ канала Tixati из пароля и проверяет пары «пароль → хэш».

Схема: `base32_lower_nopad(clamp25519(SHA-256(utf8(пароль))))`.

## Формат данных

CSV с разделителем `;`, первая строка — заголовок на английском:

```
password;hash;channel;note
iBwTOhLCvXTnrKBb;6djt7zrplpu4ywsyycsf4dde5txch2cumtezwu4idxvebw7cjzza;chan-ywlezb;main
```

- `password` — пароль (обязателен);
- `hash` — ключ канала (для `verify` обязателен, для `encode` может быть пустым);
- `channel`, `note` — необязательны и не проверяются: `encode` переносит их
  в вывод как есть, `verify` игнорирует.

Строка заголовка распознаётся по `password` в первом поле (регистр не важен)
и может отсутствовать. Поля с `;` или кавычками берутся в кавычки по
правилам CSV. Пример: [`tixati-channel-key.example.csv`](tixati-channel-key.example.csv)
(случайные данные).

## Как пользоваться

```
tixati-channel-key.py encode ApHfkCDJs8XX "ещё пароль"  # печатает password;hash
tixati-channel-key.py encode -f channels.csv            # заполняет колонку hash
tixati-channel-key.py verify ApHfkCDJs8XX 4chqjn3n5gj5rrf3yyjzipu52rf3hls362r27zjrxscmj5w42rka
tixati-channel-key.py verify -f channels.csv            # STATUS;password;hash
tixati-channel-key.py encode a b | tixati-channel-key.py verify
```

На Windows запускайте через `py`:

```powershell
py .\tixati-channel-key.py verify -f .\tixati-channel-key.example.csv
py .\tixati-channel-key.py encode -f channels.csv > channels.filled.csv
```

`verify` печатает по строке `STATUS;password;hash` на каждую запись, где
`STATUS` — `OK`, `MISMATCH` или `INVALID`; причина `INVALID` (с номером строки)
уходит в stderr. Ключ принимается в любом регистре, с паддингом `=` или без
него, и сравнивается за постоянное время.

В PowerShell нет перенаправления `<`, поэтому для файлов есть ключ `-f`.
Без `-f` и аргументов скрипт читает CSV из stdin.

Ввод всегда читается как UTF-8 (BOM игнорируется, CRLF допустим), вывод
пишется в UTF-8 независимо от кодовой страницы консоли. В Excel сохраняйте
как «CSV UTF-8»: обычный «CSV» в русской локали пишется в cp1251, и скрипт
откажется его читать.

Коды выхода: `0` — всё совпало, `1` — есть несовпадение, `2` — неверный ввод
(пустой пароль, нет хэша или он битый, файл не найден или не в UTF-8).

`channels.csv` и `pairs.txt` добавлены в `.gitignore`: в них могут быть
секретные пароли.

## Ограничения

- Схема подтверждена на ASCII-пароле; для не-ASCII паролей предполагается
  UTF-8.
- Ключ из короткого или распространённого пароля легко подобрать по словарю.
  Для настоящих каналов берите длинную случайную фразу.
- Нужен Python 3.10+, внешних зависимостей нет.
