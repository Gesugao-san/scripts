# tixati-channel-key.py

Выводит ключ канала Tixati из строки и проверяет пары «строка → ключ».

Схема: `base32_lower_nopad(clamp25519(SHA-256(utf8(строка))))`.

## Как пользоваться

```
tixati-channel-key.py encode hashme "ещё строка"   # печатает СТРОКА<TAB>КЛЮЧ
tixati-channel-key.py encode -f strings.txt        # строки из файла
tixati-channel-key.py verify hashme aaqixfadvb67t5hnnmxoezl67ksysatljthjvtgi5cs36pljhrda
                                                   # OK / MISMATCH / INVALID
tixati-channel-key.py verify -f pairs.txt          # пары СТРОКА<TAB>КЛЮЧ
tixati-channel-key.py encode a b | tixati-channel-key.py verify
```

На Windows запускайте через `py`:

```powershell
py .\tixati-channel-key.py verify -f pairs.txt
py .\tixati-channel-key.py encode a b | py .\tixati-channel-key.py verify
```

В PowerShell нет перенаправления `<`, поэтому для файлов есть ключ `-f`.
Если не переданы ни строки, ни `-f`, скрипт читает stdin, по одной записи
на строку.

Ввод всегда читается как UTF-8 (BOM в начале файла игнорируется, CRLF
допустим), вывод пишется в UTF-8 независимо от кодовой страницы консоли.
Поэтому `pairs.txt`, сохранённый Блокнотом, подходит как есть.

Коды выхода: `0` — всё совпало, `1` — есть несовпадение, `2` — неверный ввод
(битый ключ или строка, нет файла).

`verify` принимает ключ в любом регистре, с паддингом `=` или без него, и
сравнивает ключи за постоянное время.

`pairs.txt` добавлен в `.gitignore`: в нём могут быть секретные фразы.

## Ограничения

- Схема подтверждена на ASCII-строке (`hashme`); для не-ASCII строк
  предполагается UTF-8.
- Ключ из короткой или распространённой строки легко подобрать по словарю.
  Для настоящих каналов берите длинную случайную фразу.
- Нужен Python 3.10+, внешних зависимостей нет.
