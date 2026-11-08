# tixati-channel-key.py

Выводит ключ канала Tixati из строки и проверяет пары «строка → ключ».

Схема: `base32_lower_nopad(clamp25519(SHA-256(utf8(строка))))`.

## Как пользоваться

```
tixati-channel-key.py encode hashme "ещё строка"   # печатает СТРОКА<TAB>КЛЮЧ
tixati-channel-key.py verify hashme aaqixfadvb67t5hnnmxoezl67ksysatljthjvtgi5cs36pljhrda
                                                   # OK / MISMATCH / INVALID
tixati-channel-key.py encode a b | tixati-channel-key.py verify
tixati-channel-key.py verify < pairs.txt           # пары СТРОКА<TAB>КЛЮЧ
```

Если строки не переданы аргументами, `encode` читает их из stdin, по одной
на строку.

Коды выхода: `0` — всё совпало, `1` — есть несовпадение, `2` — неверный ввод.

`verify` принимает ключ в любом регистре, с паддингом `=` или без него, и
сравнивает ключи за постоянное время.

## Ограничения

- Схема подтверждена на ASCII-строке (`hashme`); для не-ASCII строк
  предполагается UTF-8.
- Ключ из короткой или распространённой строки легко подобрать по словарю.
  Для настоящих каналов берите длинную случайную фразу.
- Нужен Python 3.10+, внешних зависимостей нет.
