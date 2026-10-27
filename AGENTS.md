# AGENTS.md — DN1Sup Extension Store

> **ОБЯЗАТЕЛЬНО ПРОЧИТАТЬ ПЕРЕД РАБОТОЙ — общие правила разработки:**
> мастер `U:\dn1code\sketchup_ext\AGENTS.md` — единственная полная копия
> (публикация: `U:\dn1code\sketchup_ext\PUBLISHING.md`).

- Расширение: `dn1sup_extension_store` / имя: «DN1Sup Extension Store».
- **Каталог без готового списка**: в расширении нет статичного списка
  расширений — он запрашивается через GitHub API (репозитории `dn1sup_*`
  аккаунта `dn1test`); метаданные — из per-repo `registry.json`.
- Критичное: один id без `_dev`-двойников; версию поднимать в двух
  местах (`ext.version` регистратора, `VERSION` в `main.rb`); релиз — только при
  зелёных тестах. Локальный чек-лист публикации — в `PUBLISHING.md` этого
  репозитория.

## Локальные правила репозитория

- **Версия менеджера** хранится в коде в двух местах: `src/dn1sup_extension_store.rb`
  (`extension.version` в лоадере) и `src/dn1sup_extension_store/main.rb` (`VERSION`);
  при расхождении — приводить к одному значению. Готового списка расширений
  в расширении нет (каталог — запросом к GitHub), `registry.json` в корне
  репозитория удалён.
- **Иконки:** `icons/` в корне — источник (`store.svg` + PNG 16/24/32);
  `src/dn1sup_extension_store/icons/` — копия для .rbz. Знак един для тулбара,
  меню (`catalog_command`) и шапки GUI (`Header.vue`). Знаки продуктов в
  `icons/products/` — источник `tools/make_icons.rb` для раздачи в
  репозитории расширений (`tools/apply_icons.rb`); в .rbz менеджера
  не пакуются.
- **Тесты:** `ruby test/smoke_test.rb`; после изменений — коммит и push.
- Версии других расширений DN1Sup ведутся в их собственных репозиториях —
  здесь их не дублировать.
