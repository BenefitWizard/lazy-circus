# Research — Поддержка оплаты Telegram Stars (XTR) в Lazy Circus

**Дата:** 2026-08-16
**Тип:** исследовательские находки (без изменений кода)
**Вопрос:** что готово и что нужно подготовить, чтобы поддержать в Telegram-методах фреймворка обработку оплаты звёздами (Telegram Stars) и выставление счетов на оплату звёздами.

---

## 1. Резюме

- **Библиотека `telegram-bot-api` полностью готова** — все нужные методы и типы уже есть в pinned-коммите и реэкспортированы через umbrella-модуль `Telegram.Bot.API`, который проект импортирует как `TGAPI`.
- **Фреймворк Lazy Circus платежей не касается** — единственное упоминание это поля-заглушки `messageInvoice = Nothing` / `messageSuccessfulPayment = Nothing` в `defaultMessage` (`src/LazyCircus/Telegram/Default.hs`).
- **Главный пробел — не DSL, а обработчик апдейтов**: `handleScenario` (`common/BotHandler.hs`) смотрит только `updateMessage update >>= messageText`, поэтому `pre_checkout_query` и `successful_payment` молча игнорируются.
- **Архитектурный риск:** per-chat сериализация через `withChatState` (`MVar` на чат) может не уложиться в 10-секундный дедлайн ответа на `pre_checkout_query`, если чат занят долгой операцией (например, AI-вызовом).

---

## 2. Что даёт библиотека (проверено по pinned-коммиту)

`stack.yaml` фиксирует `fizruk/telegram-bot-simple` @ `494251f7cde155955add20f62e1bfc03ea98eba7` (subdirs: `telegram-bot-api`, `telegram-bot-simple`). В `telegram-bot-api/src/Telegram/Bot/API/Payments.hs` уже есть:

| Метод | Сигнатура | Назначение |
|---|---|---|
| `sendInvoice` | `SendInvoiceRequest -> ClientM (Response Message)` | Выставить счёт сообщением в чат |
| `createInvoiceLink` | `CreateInvoiceLinkRequest -> ClientM (Response Text)` | Создать ссылку-счёт (для сообщений вне чата бота) |
| `answerPreCheckoutQuery` | `AnswerPreCheckoutQueryRequest -> ClientM (Response Bool)` | Подтвердить/отклонить платёж перед списанием |
| `answerShippingQuery` | `AnswerShippingQueryRequest -> ClientM (Response Bool)` | Для физ. товаров с доставкой — для Stars не нужен |
| `refundStarPayment` | `RefundStarPaymentRequest -> ClientM (Response Bool)` | Возврат звёзд пользователю |

Для `SendInvoiceRequest` / `CreateInvoiceLinkRequest` сгенерированы `makeDefault`-умолчания (`defSendInvoice`, `defCreateInvoiceLink`).

**Специфика Stars (XTR):**
- `providerToken = ""` (пустая строка — именно так включается режим Stars);
- `currency = "XTR"`;
- цены — `[LabeledPrice]` в **целых звёздах** (без minor units);
- при оплате звёздами поля `needName`/`needPhoneNumber`/`needEmail`/`needShippingAddress` и т.п. неприменимы.

**Типы апдейтов готовы** (`Telegram.Bot.API.GettingUpdates` / `Types`):
- `Update.updatePreCheckoutQuery :: Maybe PreCheckoutQuery`
- `Update.updateShippingQuery :: Maybe ShippingQuery`
- `Message.messageSuccessfulPayment :: Maybe SuccessfulPayment` c полями `successfulPaymentTelegramPaymentChargeId`, `successfulPaymentInvoicePayload`, `successfulPaymentTotalAmount` и др.

**Umbrella-модуль `Telegram.Bot.API` уже реэкспортирует `Telegram.Bot.API.Payments`** — отдельный импорт не обязателен (проект и так импортирует его как `TGAPI` в `src/LazyCircus/Telegram.hs`).

Проверено по https://core.telegram.org/bots/payments-stars — флоу Stars:
1. Бот шлёт `sendInvoice` (XTR, пустой provider token).
2. Пользователь жмёт Pay → бот получает апдейт с `pre_checkout_query`.
3. Бот ОБЯЗАН ответить `answerPreCheckoutQuery` в течение **10 секунд**, иначе платёж таймаутится.
4. При успехе приходит `message` с `successful_payment` (внутри `telegram_payment_charge_id` и `invoice_payload`).
5. Возврат — `refundStarPayment` по `telegram_payment_charge_id`.

---

## 3. Паттерн расширения Telegram-эффекта в фреймворке

Добавление TG-операции в Lazy Circus затрагивает 6 точек (образец — `editMessageText` / `answerCallbackQuery`):

1. `src/LazyCircus/Scene/Telegram/Lang.hs` — конструкторы `TelegramScriptF` + смарт-конструкторы + ветки `Functor`;
2. `src/LazyCircus/Scene/Telegram/Class.hs` — методы `TelegramScriptPerformer` + ветки `runTelegram`;
3. `src/LazyCircus/Telegram.hs` — обёртки `runClientM TGAPI.sendInvoice ...` по образцу `sendDocument` + политика ошибок (`handleClientError` / `throwString`);
4. `src/LazyCircus/Performer/Default.hs` — инстанс-методы с `timedAndLog "Telegram" "SendInvoice"` (автоматический тайминг, ручные логи start/finish не нужны);
5. `src/LazyCircus/Scene/Telegram.hs` — реэкспорты стабильного фасада;
6. `src/LazyCircus/Testing/Performer.hs` — моки для `TestPerformer` (режим `Mocked`: публикация `OutgoingMessage` с новым `OutgoingKind` в STM-mailbox; режим `Real`: делегация продакшн-клиенту).

Для платежей предлагаются операции: `SendInvoice`, `CreateInvoiceLink`, `AnswerPreCheckoutQuery`, `RefundStarPayment` (`AnswerShippingQuery` для Stars не нужен, но добавить его в DSL дёшево для полноты).

---

## 4. Пробелы и план работ

### 4.1 DSL и перформеры (см. §3)
Механическая работа по образцу. Haddock-контракты (`PRE-CONTRACT` / `POST-CONTRACT`) обязательны для всех экспортируемых функций.

### 4.2 Обработчик апдейтов — главный пробел

`handleScenario` (`common/BotHandler.hs:100`) обрабатывает только текстовые сообщения. Нужно добавить ветки:

- `updatePreCheckoutQuery` → сразу `answerPreCheckoutQuery ok=True` (валидацию цены/заказа делать по `successful_payment`, т.к. она идемпотентна и приходит после реального списания);
- `updateMessage >>= messageSuccessfulPayment` → идемпотентная выдача товара/привилегии по `invoicePayload` + запись платежа в БД.

### 4.3 Бизнес-слой / БД

- Персист платежей: таблица платежей (payload → заказ, `telegram_payment_charge_id` для возвратов, статус);
- Sqitch-миграция + beam DB-сервис + регистрация в service library (по `docs/skills/lazy-circus/reference/extension.md`);
- идемпотентность выдачи по `invoicePayload` (повторная доставка `successful_payment` не должна выдавать дважды).

### 4.4 Тестовая инфраструктура

- `src/LazyCircus/Testing/Updates.hs` — фабрики `mkPreCheckoutQueryUpdate`, `mkSuccessfulPaymentUpdate` (JSON-подход как у `mkTextUpdate`);
- `src/LazyCircus/Testing/TgTest.hs` — новые `OutgoingKind` (напр. `OutSendInvoice`, `OutAnswerPreCheckout`, `OutRefundStars`) + при необходимости `waitFor*`-операции;
- сценарные тесты полного флоу: инвойс → pre-checkout → successful_payment → выдача.

---

## 5. Архитектурный риск: 10-секундный дедлайн pre-checkout

`runUpdate` (`common/BotHandler.hs:279`) заворачивает КАЖДЫЙ апдейт чата в `withChatState` (взаимная блокировка `MVar` на чат). Если в момент оплаты чат занят долгой операцией (AI-вызов на десятки секунд — штатный кейс демо-бота), `pre_checkout_query` встанет в очередь на `MVar` и не получит ответ за 10 секунд → **платёж таймаутится у пользователя**.

**Рекомендация:** обрабатывать `pre_checkout_query` вне per-chat lock — отвечать ok немедленно (это безопасно: реальные деньги списываются только после подтверждения, а финальная валидация идемпотентно выполняется на `successful_payment`, который уже может идти через обычную сериализацию).

---

## 6. Чек-лист приёмки (для будущего плана)

- [ ] `hpack` запущен перед сборкой/тестами
- [ ] Все 6 точек расширения (§3) обновлены, фасад `LazyCircus.Scene.Telegram` реэкспортирует новое
- [ ] Haddock-контракты на экспортируемые функции
- [ ] Pre-checkout не блокируется per-chat `MVar` (§5)
- [ ] Выдача по `successful_payment` идемпотентна (повтор апдейта безопасен)
- [ ] `telegram_payment_charge_id` сохраняется — без него возврат невозможен
- [ ] Тесты: фабрики апдейтов + моки + e2e-сценарий оплаты
- [ ] Логи: решения в ветках (`logInfo` в `ScenarioProgram`), без пользовательских данных в тексте лога
