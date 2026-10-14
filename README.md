# SoundCollab / Xiao Entertainment

Україномовний first-working GitHub Pages концепт платформи для музичної індустрії та суміжних event-професіоналів. Сайт показує напрямок продукту, ролі клієнта й спеціаліста, пошук/запит, маркетплейс, order workspace, журнал, Академію та модель монетизації.

## Сторінки платформи

- `index.html` — головна та швидкий запит.
- `services.html` — каталог: songwriting, mixing, mastering, production, studio booking, equipment consulting.
- `about.html` — Xiao Entertainment / SoundCollab, підхід і Studio/Journal/Academy.
- `portfolio.html` — demo-приклади робіт без непідтверджених сторонніх медіа.
- `client.html` — UI-концепт кабінету замовника: orders, status, payment state, workspace, files.
- `specialist.html` — UI-концепт кабінету виконавця: assigned orders, status update, payout terms.
- `payments.html`, `rights.html`, `responsibility.html` — пояснення безпечної оплати, прав і відповідальності.
- `faq.html`, `contact.html` — FAQ із власним запитанням, робочий email/телефон і order form fallback.

## Запуск локально

Це статичний сайт без фреймворку та залежностей:

```bash
python3 -m http.server 8000
# відкрити http://localhost:8000
```

Вхідна сторінка — `index.html`, стилі — `styles.css`, інтерактивність — `script.js`. Для demo-запитів форми валідовують базові поля й відкривають `mailto:hello@soundcollab.space`; сервер або секрети не потрібні. Замініть email і телефон у HTML/`script.js` на підтверджені перед публічним запуском.

## Що є в демо

- Українська landing page з адаптивною навігацією, пошуковим запитом (послуга, місто/онлайн, дата, кількість, бюджет) і CTA реєстрації спеціаліста.
- Категорії звуку/продакшну, студій/локацій, подій і візуалу; приклади профілів із портфоліо-логікою та verified-статусом.
- Візуальний demo order workspace: задачі, файли, статус, дедлайн і order-scoped chat.
- Контентні напрямки: SoundCollab Journal (журналістика/огляди обладнання) та Academy (платні курси, включно з навчанням мікшеру/консолі).
- Зафіксована бізнес-модель: **10% комісія з кожної успішної транзакції**, paid Boost, Studio Membership із пріоритетним бронюванням і paid Academy courses.

Це не production-продукт: немає реальної автентифікації, бази даних, повідомлень, платежів, бронювання, пошуку чи збереження заявок. Картки, прогрес workspace і chat — UI-демо. Не вводьте на сторінці чутливі дані.

## Архітектура та production-план

Поточний шар — легкий статичний marketing/demo shell, який можна опублікувати з `main`. Наступний шар має винести UI на API з role-based доступом:

- **Ролі:** client створює запит/замовлення, приймає deliverables і залишає review; specialist створює профіль, портфоліо, послуги й пропозиції; studio — локація, доступність і правила бронювання; admin/moderator — trust & safety.
- **Notifications:** email/in-app сповіщення про offer, дедлайн, файл, повідомлення, оплату та скасування; налаштування opt-in і часовий пояс.
- **Storage:** приватне object storage для аудіо/відео, signed URLs, обмеження розміру, версії файлів і retention; metadata та права — у БД.
- **Calendar:** часові слоти й timezone-aware availability спеціаліста/студії, hold на час оплати, синхронізація лише після явної згоди.
- **Privacy:** мінімізація даних, export/delete account, прозорий consent для портфоліо, окремі правила для cookies/analytics, українська privacy policy та GDPR-ready процеси.
- **Trust & safety:** верифікація, report/block, moderation портфоліо, dispute workflow, заборона шахрайства/піратського контенту та аудит moderation-рішень.
- **Payments:** checkout через ліцензованого PSP, 10% platform fee у server-side ledger, payout після приймання/тайм-ауту, invoice/receipt. Ключі та webhook secrets — тільки в GitHub Actions secrets або hosting secret store.
- **Cancellations:** до старту — повне повернення за правилами замовлення; після старту — milestone/пропорційне повернення; dispute та mediation для спірних deliverables. Правила показуються до checkout.
- **Rights/licensing:** замовник і спеціаліст явно фіксують ownership, commercial usage, samples, stems і credit у замовленні; платформа не ліцензує контент за замовчуванням.
- **Telegram/contact fallback:** до появи API лишається `mailto`; для support можна додати Telegram deep link без токенів. Не вбудовувати bot token у frontend.

## GitHub Pages

`.github/workflows/pages.yml` використовує офіційний Pages artifact flow: push у `main` запускає checkout → upload artifact → deploy. У Settings → Pages потрібно обрати **GitHub Actions** (workflow вже задає `pages: write` і OIDC). Для custom domain додайте `CNAME` після налаштування DNS. Будь-який endpoint або payment integration має бути server-side; GitHub Pages — лише статичний frontend.

## Ліцензування

У репозиторії немає сторонніх шрифтів, фото чи треків: візуальні картки — CSS-ілюстрації. Перед production треба замінити demo visuals на контент із підтвердженими правами та додати `LICENSE`/terms для user-generated content.
