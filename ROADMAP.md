# SoundCollab roadmap

## Phase 0 — статичне демо (завершено)

- [x] Українська responsive landing page та рольова подача client/specialist.
- [x] Пошук/запит: service, city/online, date, quantity, budget.
- [x] Demo workspace: tasks, files, order-scoped chat, статус і дедлайн.
- [x] Marketplace, studio booking direction, Journal, Academy і monetization model.
- [x] Safe `mailto` fallback без секретів.
- [x] GitHub Pages workflow та документація demo limitations.

## Phase 1 — MVP на Supabase (реалізовано, потрібен ручний acceptance test)

- [x] Email signup/login/logout, email confirmation, password recovery, consent та профілі з ролями client/performer.
- [x] Замовлення з послугою, описом, бюджетом, форматом, дедлайном і вибором спеціаліста.
- [x] DB-перевірки дозволених переходів статусу та ролей; незмінний order event log.
- [x] Приватний order-scoped чат через Realtime, зустрічі з підтвердженням другою стороною та спори з DB admin access.
- [x] Профіль виконавця, прийняття/відхилення запиту, передача результату посиланням або приватним файлом.
- [x] RLS на всіх створених таблицях, приватний Storage bucket і налаштування через `supabase/schema.sql`.
- [ ] Налаштувати окремий Supabase project, перевірити redirect URLs/email/Storage limits і пройти повний сценарій з двома акаунтами та адміністратором з `README.md`.
- [ ] Перевірити RLS/security сценарії в тестовому Supabase проєкті до публічного використання.

## Phase 2 — ручна перевірка попиту й експлуатаційна готовність

- [ ] Опублікувати landing page та заповнити контактний fallback (email/Telegram instructions) без секретів у frontend.
- [ ] Зібрати базу з 10–20 спеціалістів: роль, місто, жанри, ставка, портфоліо, контакт, доступність.
- [ ] Провести перші 3–5 угод вручну й записати, де клієнтам потрібні фільтри, які ціни та строки повторюються.
- [ ] Погодити з першими спеціалістами правила роботи через SoundCollab, 10% commission, cancellation та rights templates.
- [ ] Перевірити, що verified означає лише підтверджену identity/portfolio/availability перевірку, а не гарантію якості.
- [ ] Увімкнути SMTP/transactional email, моніторинг, backup/restore, retention і процес export/delete; поки email лише для Auth-підтвердження та recovery.

## Phase 3 — production foundation

- [ ] Залишити Supabase як керований backend без власного сервера; виконати security review RLS, audit та dependency review перед реальними даними.
- [ ] Додати явне керування consent, privacy center, export/delete, retention та доступністю.
- [ ] Профілі спеціалістів: портфоліо, rate card, availability, reviews, verification.
- [ ] Реальний search index із фільтрами та city/online coverage.
- [ ] Приватне object storage для media, signed links, virus scan, versioning.
- [ ] Transactional email та in-app notification center.

## Phase 4 — угоди та гроші

- [ ] Зафіксувати юридичні правила offer → checkout → acceptance → payout та cancellation/dispute до підключення платежів.
- [ ] PSP integration, серверна 10% commission ledger, refunds, invoices та webhooks; секрети й перевірки оплат ніколи не переносяться на GitHub Pages.
- [ ] Calendar availability, studio booking holds, timezone handling.
- [ ] Розширити MVP workspace: tasks, версії файлів, безпечний moderation та права/licensing flow.

## Phase 5 — growth

- [ ] Paid Boost із чітким маркуванням sponsored placement.
- [ ] Studio Membership: правила priority booking, capacity і billing.
- [ ] Academy: paid courses, author dashboard, video delivery, completion tracking.
- [ ] Journal CMS, equipment reviews, editorial policy, affiliate disclosure.
- [ ] Analytics only with consent, privacy center, export/delete account.

## Phase 6 — ecosystem

- [ ] Telegram/support integration через server-side bot service.
- [ ] Calendar integrations за opt-in, mobile PWA, Ukrainian/English localization.
- [ ] Team workspaces, recurring events, venue contracts та B2B invoicing.
- [ ] Trust signals, safety reporting metrics і independent payout/dispute review.

## Definition of done для production

Жоден UI-елемент не називається real/verified без backend proof. Усі платежі, права, cancellation terms і storage permissions мають бути видимі користувачу до дії; secrets не потрапляють у frontend або репозиторій; accessibility, backup/restore, monitoring і incident response перевірені до запуску.

## Що свідомо відкладено

До появи повторюваного попиту не будуємо повний DAW/workspace із мультитреком і waveform, маркетплейс бітів/семплів/пресетів, складну систему рейтингів, прокат обладнання або велику медіа-Академію. На старті ці напрямки залишаються контентними demo-секціями, а не заявленими production-функціями.

## Підтверджені рішення та відкриті питання

Підтверджено: українська first-версія, client/specialist/studio ролі, **10% комісія з успішної транзакції**, paid Boost, Studio Membership із priority booking і paid Academy courses. Потрібна окрема юридична та бухгалтерська консультація щодо форми бізнесу, податків, PSP, договорів, авторських прав і GDPR; ці питання не маскуються UI як уже вирішені.
