# Fire-and-forget cast для сервисов ServiceLib (семантика gen_server)

## Зафиксированные решения
1. **Транспорт — единый mailbox**: одна `TQueue` с конвертами `CallMsg`/`CastMsg`, свой response-`TMVar` на каждый вызов, строгий FIFO между call и cast, один сериализованный воркер. `QSem` и `Pipe` (MVar-пара) уходят. Дельта стоимости — один TMVar (~наносекунды) на call.
2. **Тестовый перформер — доставка + запись**: cast реально уходит в воркер (как call) и дополнительно пишется в буфер `Mocks` (по образцу `readTgRequests`) — детерминированные ассерты «отправки» + реальная обработка.

## 1. `src/LazyCircus/App/Service.hs` — транспорт
- Новый тип `Envelope request response = CallMsg request (TMVar response) | CastMsg request` (+Haddock по стилю AGENTS.md).
- `ServiceHandler a b = ServiceHandler { serviceHandlerMailbox :: TQueue (Envelope a b) }`.
- Удалить `Request`/`Response`/`Pipe`-алиасы, `createPipe` и старый `worker` — внешних пользователей в репо нет (проверено grep'ом).
- Новый `worker`: один `readTQueue`; `CastMsg` → `tryAny (castF a)`, исключение молча проглотить; `CallMsg` → `tryAny (callF a)` → `putTMVar reply` (failback при ошибке, как сейчас). Воркер переживает исключения обоих видов.
- `createService f = createServiceWithCast (void . f) f` — cast по умолчанию исполняет тот же хендлер, результат отброшен (каждый TH-сервис получает cast бесплатно).
- Новый `createServiceWithCast :: (a -> m ()) -> (a -> m b) -> m (ServiceHandler a b, m ())` — ручной путь для отдельного «handle_cast».
- `callService`: `newEmptyTMVarIO` → enqueue `CallMsg` → `readTMVar` (достаточно `MonadIO`; constraint в классе не трогаем).
- Новый `castService :: MonadIO m => ServiceHandler a b -> a -> m ()`: `writeTQueue` и сразу вернуть управление.
- `IsInServiceLib`: добавить `castFromServiceLib :: MonadUnliftIO m => serviceLib -> request -> m ()` **с default** = блокирующий fallback через `callFromServiceLib` (все ручные инстансы продолжают компилироваться).
- Новый `castViaServiceLib` — зеркало `callViaServiceLib`.
- Обновить экспорты и заголовок модуля (SCOPE: mailbox вместо MVar-каналов).

## 2. `src/LazyCircus/Scenario.hs`
- Конструктор фунтора: `CastService :: (S.IsInServiceLib sl req res, Typeable req) => req -> Scenario script sl a` (результат напрямую, как `RunAsync`; `Typeable` нужен для записи `Dynamic` в тест-буфер — инстансы автоматические).
- Кейс в `Functor`-инстансе и в `run`.
- `ScenarioPerformer`: метод `castService' :: (S.IsInServiceLib sl req res, Typeable req) => request -> m ()` — **без default** (прецедент `runAsyncAfter'`; ломает внешние кастомные перформеры — задокументировать в доке класса).
- Смарт-конструктор `castService :: ... => request -> ScenarioProgram script serviceLib ()` с честным Haddock: управление возвращается до обработки; гарантий доставки нет; ошибки хендлера проглатываются воркером; mailbox безграничен (backpressure нет, при необходимости `TQueue`→`TBQueue` позже).
- Экспортировать новое.

## 3. `src/LazyCircus/Performer/Default.hs`
- `castService' = castViaServiceLib`.

## 4. `testing/src/LazyCircus/Testing/Performer.hs`
- `Mocks`: новое поле `castRequests :: SomeRef [Dynamic]` (+инициализация в месте сборки `Mocks`, ~строка 955).
- `castService' req = записать (toDyn req) в буфер >> castViaServiceLib req` — запись синхронна на шаге сценария.
- Ридеры + экспорт: `readCastRequests :: Mocks sl -> IO [Dynamic]` и типизированный `readCastRequestsOfType :: Typeable req => Mocks sl -> IO [req]`.

## 5. `src/LazyCircus/App/Service/TH.hs`
- `genIsInServiceLibInstances`: эмитить и `castFromServiceLib = \x -> castService (fieldNameService lib x)` — перекрывает блокирующий default, TH-библиотеки получают настоящий async cast без изменений конфига.
- Обновить док-коммент списка генерируемого.

`common/SimpleService*.hs` менять не нужно: сигнатура `createService` сохранена, TH пересоберётся.

## 6. Тесты — новый `test/ServiceCastSpec.hs` (root-сьют, hspec-discover подхватит сам; нужен PG, харнесс по образцу `ServiceCallSpec`)
- доставка: хендлер сигнализирует в MVar/IORef, ожидание с таймаутом;
- неблокируемость: хендлер, ждущий на MVar, — `castService` возвращается немедленно (`System.Timeout`);
- FIFO: маркеры в IORef — call после cast обрабатывается позже cast'а;
- живучесть воркера: cast-путь кидает исключение → последующий call работает;
- TH-инстанс действительно async (не блокирующий default);
- буфер: `readCastRequestsOfType` возвращает отправленный cast.

`ServiceCallSpec` должен пройти без правок (семантика call сохранена; для одиночного вызывающего FIFO неотличим от QSem).

## 7. Документация
- `docs/skills/lazy-circus/reference/extension.md`: переписать «How It Works» под mailbox, шаги регистрации (+cast), список генерируемого TH, pitfalls (тихие ошибки cast, безграничный mailbox, блокирующий default ручных инстансов), чеклисты.
- `docs/skills/lazy-circus/reference/scenarios.md`: `castService` в таблицу операций и список сигнатур (~строки 101, 122).
- `docs/skills/lazy-circus/reference/runtime.md`: строка о cast в dispatch paths.
- Синхронизировать зеркальную копию `~/.agents/skills/lazy-circus/reference/` (оттуда грузится скилл).

## 8. Сборка и проверка
- `hpack && hpack testing` → `stack test` (root-сьют требует PostgreSQL на 127.0.0.1:5432) и `stack test lazy-circus-testing` (DB-free).