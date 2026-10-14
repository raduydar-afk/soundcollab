# SoundCollab roadmap

## Phase 0 — demo (зараз)

- [x] Українська responsive landing page та рольова подача client/specialist.
- [x] Пошук/запит: service, city/online, date, quantity, budget.
- [x] Demo workspace: tasks, files, order-scoped chat, статус і дедлайн.
- [x] Marketplace, studio booking direction, Journal, Academy і monetization model.
- [x] Safe `mailto` fallback без секретів.
- [x] GitHub Pages workflow та документація demo limitations.

## Phase 1 — ручна перевірка попиту

- [ ] Опублікувати landing page та заповнити контактний fallback (email/Telegram instructions) без секретів у frontend.
- [ ] Зібрати базу з 10–20 спеціалістів: роль, місто, жанри, ставка, портфоліо, контакт, доступність.
- [ ] Провести перші 3–5 угод вручну й записати, де клієнтам потрібні фільтри, які ціни та строки повторюються.
- [ ] Погодити з першими спеціалістами правила роботи через SoundCollab, 10% commission, cancellation та rights templates.
- [ ] Перевірити, що verified означає лише підтверджену identity/portfolio/availability перевірку, а не гарантію якості.

## Phase 2 — foundation

- [ ] Додати API, PostgreSQL schema та auth (email/OAuth) з чіткими ролями client, specialist, studio, moderator.
- [ ] Профілі спеціалістів: портфоліо, rate card, availability, reviews, verification.
- [ ] Реальний search index із фільтрами та city/online coverage.
- [ ] Приватне object storage для media, signed links, virus scan, versioning.
- [ ] Transactional email та in-app notification center.

## Phase 3 — order lifecycle

- [ ] Offer → checkout → active order → acceptance → payout state machine.
- [ ] PSP integration, server-side 10% commission ledger, refunds, invoices та webhooks.
- [ ] Calendar availability, studio booking holds, timezone handling.
- [ ] Workspace tasks/files/comments/chat з access control і audit log.
- [ ] Cancellation, dispute, moderation і rights/licensing flows.

## Phase 4 — growth

- [ ] Paid Boost із чітким маркуванням sponsored placement.
- [ ] Studio Membership: правила priority booking, capacity і billing.
- [ ] Academy: paid courses, author dashboard, video delivery, completion tracking.
- [ ] Journal CMS, equipment reviews, editorial policy, affiliate disclosure.
- [ ] Analytics only with consent, privacy center, export/delete account.

## Phase 5 — ecosystem

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
