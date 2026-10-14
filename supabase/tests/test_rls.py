"""SoundCollab database tests: simulate Supabase roles (anon / authenticated / admin)
against supabase/schema.sql on a plain Postgres. Connection comes from the standard
libpq variables (PGHOST, PGUSER, PGPASSWORD, PGDATABASE). Set SC_APPLY_SCHEMA=1 to also
load supabase/tests/mock_supabase.sql + supabase/schema.sql into an EMPTY database first.
Exit code is non-zero if any check fails."""
import json, os, sys, uuid, psycopg2

HERE = os.path.dirname(os.path.abspath(__file__))
conn = psycopg2.connect(dbname=os.environ.get("PGDATABASE", "sc_test"))
conn.autocommit = True
cur = conn.cursor()
if os.environ.get("SC_APPLY_SCHEMA"):
    for path in (os.path.join(HERE, "mock_supabase.sql"), os.path.join(HERE, "..", "schema.sql")):
        with open(path, encoding="utf-8") as fh:
            cur.execute(fh.read())
T = []  # (section, name, passed, detail)
SEC = ["?"]


def R(uid, q, a=None, role="authenticated"):
    cur.execute("begin")
    try:
        if role != "postgres":
            cur.execute(f"set local role {role}")
        if uid:
            cur.execute("select set_config('request.jwt.claim.sub', %s, true)", (uid,))
        cur.execute(q, a)
        res = cur.fetchall() if cur.description else cur.rowcount
        cur.execute("commit")
        return ("ok", res)
    except Exception as e:
        cur.execute("rollback")
        return ("err", str(e).strip().split("\n")[0])


def sup(q, a=None):
    """superuser, triggers bypassed (test fixtures only)"""
    cur.execute("begin")
    cur.execute("set local session_replication_role = replica")
    cur.execute(q, a)
    res = cur.fetchall() if cur.description else cur.rowcount
    cur.execute("commit")
    return res


def n(res):
    return len(res) if isinstance(res, list) else res


def ok(name, r):
    T.append((SEC[0], name, r[0] == "ok", r))


def err(name, r, sub=None):
    T.append((SEC[0], name, r[0] == "err" and (sub is None or sub.lower() in r[1].lower()), r))


def rows(name, r, count):
    T.append((SEC[0], name, r[0] == "ok" and n(r[1]) == count, r))


def check(name, cond, detail=""):
    T.append((SEC[0], name, bool(cond), ("info", detail)))


def sec(s):
    SEC[0] = s


# ------------------------------------------------------------------ fixtures
def mkuser(label, meta):
    uid = str(uuid.uuid4())
    cur.execute("insert into auth.users(id,email,raw_user_meta_data) values (%s,%s,%s)",
                (uid, f"{label.lower()}@test.local", json.dumps(meta)))
    return uid


def meta(roles, name, consent="true"):
    d = {"display_name": name, "roles": roles}
    if consent is not None:
        d["privacy_consent"] = consent
    return d


sec("1. Реєстрація")
try:
    mkuser("nocons", meta(["client"], "NoConsent", consent=None))
    T.append((SEC[0], "Без згоди на конфіденційність акаунт не створюється", False, ("ok", "created")))
except Exception as e:
    T.append((SEC[0], "Без згоди на конфіденційність акаунт не створюється", "consent" in str(e).lower(), ("err", str(e).split("\n")[0])))
try:
    mkuser("badcons", meta(["client"], "BadConsent", consent="yes"))
    T.append((SEC[0], "Згода зі значенням не 'true' відхиляється", False, ("ok", "created")))
except Exception as e:
    T.append((SEC[0], "Згода зі значенням не 'true' відхиляється", True, ("err", str(e).split("\n")[0])))

A = mkuser("A", meta(["client"], "Клієнт А"))
B = mkuser("B", meta(["performer"], "Виконавець Б"))
C = mkuser("C", meta(["client", "performer"], "Обидві ролі"))
D = mkuser("D", meta(["client"], "Сторонній Д"))
E = mkuser("E", meta(["client"], "Адмін Е"))
F = mkuser("F", meta(["performer"], "Виконавець Ф"))
G = mkuser("G", meta(["client"], "Клієнт Г"))
sup("update profiles set is_admin = true where id = %s", (E,))
X = mkuser("X", meta(["admin", "client"], "Хакер"))
Y = mkuser("Y", {"privacy_consent": "true", "display_name": "NoRoles"})
Z = mkuser("Z", {"privacy_consent": "true", "roles": "performer", "display_name": "BadShape"})
roles = lambda u: sup("select roles, is_admin from profiles where id=%s", (u,))[0]
check("Роль 'admin' у метаданих реєстрації ігнорується", roles(X) == (["client"], False), roles(X))
check("Без ролей у метаданих → client", roles(Y)[0] == ["client"], roles(Y))
check("Некоректний формат ролей → client", roles(Z)[0] == ["client"], roles(Z))
check("Профіль створюється з is_admin = false для всіх нових", all(roles(u)[1] is False for u in (A, B, C, D, X)))

# ------------------------------------------------------------------ profiles
sec("2. Профілі та приватність")
err("Клієнт не бачить колонку is_admin", R(A, "select is_admin from profiles where id=%s", (A,)))
err("Клієнт не бачить службові поля згоди", R(A, "select privacy_accepted_at from profiles where id=%s", (A,)))
rows("Клієнт бачить власний публічний профіль", R(A, "select id,display_name,roles from profiles where id=%s", (A,)), 1)
err("Не можна самому собі дати is_admin", R(A, "update profiles set is_admin=true where id=%s", (A,)))
err("Не можна змінити запис згоди", R(A, "update profiles set privacy_policy_version='x' where id=%s", (A,)))
err("Не можна змінити власний id", R(A, "update profiles set id=%s where id=%s", (str(uuid.uuid4()), A)))
rows("Можна змінити власне bio", R(A, "update profiles set bio='привіт' where id=%s", (A,)), 1)
rows("Не можна змінити чужий профіль (0 рядків)", R(A, "update profiles set bio='hack' where id=%s", (B,)), 0)
err("Роль 'admin' у масиві ролей відхиляється", R(A, "update profiles set roles=array['admin'] where id=%s", (A,)))
rows("Сторонній бачить профіль виконавця", R(D, "select id from profiles where id=%s", (B,)), 1)
rows("Сторонній НЕ бачить профіль клієнта без спільних замовлень", R(D, "select id from profiles where id=%s", (A,)), 0)
err("Анонім не читає профілі", R(None, "select id from profiles", role="anon"))

# ------------------------------------------------------------------ orders
INS = ("insert into orders(client_id,performer_id,service,title,description,budget,format) "
       "values (%s,%s,'mixing','Тест','Опис',100,'remote') returning id")
sec("3. Створення та редагування замовлень")
r = R(A, INS, (A, B)); ok("Клієнт створює чернетку з виконавцем", r); O1 = r[1][0][0] if r[0] == "ok" else None
err("Не можна створити одразу зі статусом requested",
    R(A, "insert into orders(client_id,service,title,description,budget,format,status) values (%s,'m','t','d',1,'remote','requested')", (A,)))
err("Не можна створити замовлення від імені іншого клієнта", R(A, INS, (D, B)))
err("Не можна призначити себе виконавцем", R(C, INS, (C, C)))
err("Не можна призначити не-виконавця", R(A, INS, (A, D)), "not a performer")
err("Від'ємний бюджет відхиляється",
    R(A, "insert into orders(client_id,service,title,description,budget,format) values (%s,'m','t','d',-5,'remote')", (A,)))
err("Невалідний формат відхиляється",
    R(A, "insert into orders(client_id,service,title,description,budget,format) values (%s,'m','t','d',5,'teleport')", (A,)))
rows("Виконавець НЕ бачить чернетку", R(B, "select id from orders where id=%s", (O1,)), 0)
rows("Сторонній не бачить замовлення", R(D, "select id from orders where id=%s", (O1,)), 0)
rows("Адмін не бачить звичайні (не спірні) замовлення", R(E, "select id from orders where id=%s", (O1,)), 0)
rows("Клієнт бачить власну чернетку", R(A, "select id from orders where id=%s", (O1,)), 1)
rows("Клієнт редагує чернетку", R(A, "update orders set title='Нова назва' where id=%s", (O1,)), 1)
rows("Виконавець не редагує чужу чернетку (0 рядків)", R(B, "update orders set title='hack' where id=%s", (O1,)), 0)
err("Пряма зміна статусу в обхід функції (draft→completed)", R(A, "update orders set status='completed' where id=%s", (O1,)))
err("Не можна змінити client_id чернетки", R(A, "update orders set client_id=%s where id=%s", (D, O1)))
err("Не можна змінити валюту", R(A, "update orders set currency='USD' where id=%s", (O1,)))

sec("4. Життєвий цикл замовлення")
TR = "select * from transition_order(%s,%s,%s)"
err("Виконавець не може запросити (draft→requested)", R(B, TR, (O1, "requested", None)))
err("Сторонній не може перевести статус", R(D, TR, (O1, "requested", None)))
ok("Клієнт відправляє запит", R(A, TR, (O1, "requested", None)))
rows("Виконавець тепер бачить запит", R(B, "select id from orders where id=%s", (O1,)), 1)
rows("Сторонній і далі не бачить", R(D, "select id from orders where id=%s", (O1,)), 0)
err("Після відправки клієнт не редагує поля", R(A, "update orders set title='зміна' where id=%s", (O1,)), "draft")
err("Сторонній не приймає замовлення", R(D, TR, (O1, "accepted", None)))
err("Клієнт не може сам прийняти", R(A, TR, (O1, "accepted", None)))
err("Не можна перестрибнути requested→in_progress", R(B, TR, (O1, "in_progress", None)))
ok("Виконавець приймає", R(B, TR, (O1, "accepted", None)))
err("Клієнт не запускає роботу", R(A, TR, (O1, "in_progress", None)))
ok("Виконавець починає роботу", R(B, TR, (O1, "in_progress", None)))
err("'Здано' без результату неможливе", R(B, TR, (O1, "delivered", None)), "deliverable")
DL = "insert into order_deliverables(order_id,submitted_by,link_url,note) values (%s,%s,%s,'нотатка')"
err("Результат з javascript:-посиланням відхиляється", R(B, DL, (O1, B, "javascript:alert(1)")))
err("Результат з ftp:-посиланням відхиляється", R(B, DL, (O1, B, "ftp://x/y")))
err("Клієнт не може завантажувати результат", R(A, DL, (O1, A, "https://drive.google.com/x")))
err("Сторонній не може завантажувати результат", R(D, DL, (O1, D, "https://drive.google.com/x")))
err("Не можна подати результат від імені іншого", R(B, DL, (O1, A, "https://drive.google.com/x")))
ok("Виконавець подає результат (https)", R(B, DL, (O1, B, "https://drive.google.com/x")))
rows("Клієнт бачить результат", R(A, "select id from order_deliverables where order_id=%s", (O1,)), 1)
rows("Сторонній не бачить результат", R(D, "select id from order_deliverables where order_id=%s", (O1,)), 0)
ok("Виконавець позначає 'здано'", R(B, TR, (O1, "delivered", None)))
err("Виконавець не завершує замовлення", R(B, TR, (O1, "completed", None)))
ok("Клієнт завершує", R(A, TR, (O1, "completed", None)))
err("Завершене не можна скасувати", R(A, TR, (O1, "cancelled", None)))
err("Завершене не можна оскаржити", R(A, TR, (O1, "disputed", "достатньо довга причина")))
err("Невідомий статус відхиляється", R(A, TR, (O1, "teleported", None)))
check("Журнал містить усі 5 переходів O1 + створення",
      sup("select count(*) from order_events where order_id=%s and event_type='status_changed'", (O1,))[0][0] == 5
      and sup("select count(*) from order_events where order_id=%s and event_type='order_created'", (O1,))[0][0] == 1)

sec("5. Відкритий запит (без призначеного виконавця)")
r = R(A, "insert into orders(client_id,service,title,description,budget,format) values (%s,'mixing','Відкритий','Опис',50,'remote') returning id", (A,))
O2 = r[1][0][0]
ok("Клієнт відправляє відкритий запит", R(A, TR, (O2, "requested", None)))
rows("Виконавець Б бачить відкритий запит", R(B, "select id from orders where id=%s", (O2,)), 1)
rows("Виконавець Ф бачить відкритий запит", R(F, "select id from orders where id=%s", (O2,)), 1)
rows("Клієнт-без-ролі-виконавця (Д) не бачить", R(D, "select id from orders where id=%s", (O2,)), 0)
err("Один виконавець не може відхилити відкритий запит для всіх", R(F, TR, (O2, "declined", None)))
ok("Виконавець Б приймає відкритий запит", R(B, TR, (O2, "accepted", None)))
check("Виконавець Б призначений на O2", str(sup("select performer_id from orders where id=%s", (O2,))[0][0]) == B)
rows("Виконавець Ф після призначення вже не бачить", R(F, "select id from orders where id=%s", (O2,)), 0)
r = R(C, "insert into orders(client_id,service,title,description,budget,format) values (%s,'m','Свій','д',5,'remote') returning id", (C,))
OC = r[1][0][0]
ok("C (обидві ролі) відправляє відкритий запит", R(C, TR, (OC, "requested", None)))
err("C не може прийняти власний запит", R(C, TR, (OC, "accepted", None)))

sec("6. Скасування та відхилення")
r = R(A, INS, (A, B)); O5 = r[1][0][0]
ok("Скасування чернетки", R(A, TR, (O5, "cancelled", None)))
r = R(A, INS, (A, B)); O6 = r[1][0][0]
R(A, TR, (O6, "requested", None))
ok("Призначений виконавець відхиляє запит", R(B, TR, (O6, "declined", None)))
err("Після відхилення не можна прийняти", R(B, TR, (O6, "accepted", None)))

# ------------------------------------------------------------------ working order for chat / meetings / disputes
r = R(A, INS, (A, B)); O4 = r[1][0][0]
for who, st in ((A, "requested"), (B, "accepted"), (B, "in_progress")):
    R(who, TR, (O4, st, None))
check("Фікстура O4 у статусі in_progress", sup("select status from orders where id=%s", (O4,))[0][0] == "in_progress")

sec("7. Чат")
MS = "insert into messages(order_id,sender_id,body) values (%s,%s,%s)"
ok("Клієнт пише в чат", R(A, MS, (O4, A, "Привіт")))
ok("Виконавець відповідає", R(B, MS, (O4, B, "<script>alert(1)</script>")))
rows("Обидва учасники бачать 2 повідомлення", R(B, "select id from messages where order_id=%s", (O4,)), 2)
rows("Сторонній не бачить чат", R(D, "select id from messages where order_id=%s", (O4,)), 0)
err("Сторонній не пише в чат", R(D, MS, (O4, D, "спам")))
err("Не можна писати від імені іншого", R(A, MS, (O4, B, "підробка")))
err("Порожнє повідомлення відхиляється", R(A, MS, (O4, A, "")))
err("Завелике повідомлення (>5000) відхиляється", R(A, MS, (O4, A, "x" * 5001)))
err("Повідомлення не можна редагувати", R(A, "update messages set body='змінено' where order_id=%s", (O4,)))
err("Повідомлення не можна видаляти", R(A, "delete from messages where order_id=%s", (O4,)))
rows("Адмін не читає чат неспірного замовлення", R(E, "select id from messages where order_id=%s", (O4,)), 0)
err("Анонім не читає чат", R(None, "select id from messages", role="anon"))

sec("8. Зустрічі")
CM = "select * from create_meeting(%s,%s,now()+interval '2 days',%s,%s,%s)"
err("Віддалена зустріч з чужим доменом відхиляється", R(A, CM, (O4, "remote", None, None, "https://evil.com/room")))
err("Віддалена зустріч по http відхиляється", R(A, CM, (O4, "remote", None, None, "http://meet.jit.si/x")))
err("Домен-обманка (meet.jit.si.evil.com) відхиляється", R(A, CM, (O4, "remote", None, None, "https://meet.jit.si.evil.com/x")))
r = R(A, CM, (O4, "remote", None, None, "https://meet.jit.si/SoundCollab-abc123")); ok("Jitsi-кімната пропонується", r)
M1 = r[1][0][0] if r[0] == "ok" else None
for dom in ("https://zoom.us/j/1", "https://us02web.zoom.us/j/1", "https://meet.google.com/abc-defg-hij", "https://teams.microsoft.com/l/meetup-join/x"):
    ok(f"Дозволено {dom.split('/')[2]}", R(A, CM, (O4, "remote", None, None, dom)))
r = R(A, CM, (O4, "in_person", "Кав'ярня 'Лева', Площа Ринок 1", "https://maps.google.com/?q=1", None)); ok("Очна зустріч у кав'ярні", r)
M2 = r[1][0][0] if r[0] == "ok" else None
err("Очна без місця відхиляється", R(A, CM, (O4, "in_person", "ab", None, None)))
err("Очна з посиланням на відео відхиляється", R(A, CM, (O4, "in_person", "Кафе", None, "https://meet.jit.si/x")))
err("Віддалена з місцем відхиляється", R(A, CM, (O4, "remote", "Кафе", None, "https://meet.jit.si/x")))
err("Карта з javascript: відхиляється", R(A, CM, (O4, "in_person", "Кафе", "javascript:alert(1)", None)))
err("Зустріч у минулому відхиляється",
    R(A, "select * from create_meeting(%s,'remote',now()-interval '1 day',null,null,'https://meet.jit.si/x')", (O4,)))
err("Сторонній не пропонує зустріч", R(D, CM, (O4, "remote", None, None, "https://meet.jit.si/x")))
err("Адмін не пропонує зустріч", R(E, CM, (O4, "remote", None, None, "https://meet.jit.si/x")))
err("Зустріч на завершеному замовленні неможлива", R(A, CM, (O1, "remote", None, None, "https://meet.jit.si/x")))
RM = "select * from respond_to_meeting(%s,%s,%s)"
err("Автор пропозиції не підтверджує сам", R(A, RM, (M1, "confirmed", None)))
err("Сторонній не відповідає", R(D, RM, (M1, "confirmed", None)))
ok("Виконавець підтверджує", R(B, RM, (M1, "confirmed", None)))
err("Повторна відповідь на підтверджену неможлива", R(B, RM, (M1, "declined", None)))
err("Перенесення без нової дати відхиляється", R(B, RM, (M2, "rescheduled", None)))
err("Перенесення на минулу дату відхиляється", R(B, "select * from respond_to_meeting(%s,'rescheduled',now()-interval '1 day')", (M2,)))
ok("Виконавець переносить зустріч", R(B, "select * from respond_to_meeting(%s,'rescheduled',now()+interval '3 days')", (M2,)))
st = sup("select status, proposer_id from meetings where id=%s", (M2,))[0]
check("Після перенесення знову 'proposed', автор — виконавець", st[0] == "proposed" and str(st[1]) == B, st)
err("Виконавець не підтверджує власне перенесення", R(B, RM, (M2, "confirmed", None)))
ok("Клієнт підтверджує нову дату", R(A, RM, (M2, "confirmed", None)))
err("Пряма зміна статусу зустрічі заборонена", R(A, "update meetings set status='confirmed' where id=%s", (M1,)))
err("Пряма вставка зустрічі заборонена (обхід валідації)",
    R(A, "insert into meetings(order_id,proposer_id,meeting_type,scheduled_at,meeting_url) values (%s,%s,'remote',now()+interval '1 day','https://evil.com')", (O4, A)))
err("Видалення зустрічі заборонене", R(A, "delete from meetings where id=%s", (M1,)))
rows("Сторонній не бачить зустрічі", R(D, "select id from meetings where order_id=%s", (O4,)), 0)
check("Зустрічі потрапили в журнал подій",
      sup("select count(*) from order_events where order_id=%s and event_type like 'meeting%%'", (O4,))[0][0] >= 5)

sec("9. Журнал подій та незмінність")
rows("Учасник бачить журнал", R(A, "select id from order_events where order_id=%s", (O4,)), sup("select count(*) from order_events where order_id=%s", (O4,))[0][0])
rows("Сторонній не бачить журнал", R(D, "select id from order_events where order_id=%s", (O4,)), 0)
err("Журнал не можна доповнювати з клієнта", R(A, "insert into order_events(order_id,event_type) values (%s,'fake')", (O4,)))
err("Журнал не можна редагувати", R(A, "update order_events set event_type='x' where order_id=%s", (O4,)))
err("Журнал не можна видаляти", R(A, "delete from order_events where order_id=%s", (O4,)))
err("Спори не створюються напряму", R(A, "insert into order_disputes(order_id,opened_by,reason) values (%s,%s,'fake reason')", (O4, A)))

sec("10. Спори й арбітраж")
err("Спір із коротким поясненням відхиляється", R(A, TR, (O4, "disputed", "ні")))
err("Сторонній не відкриває спір", R(D, TR, (O4, "disputed", "достатньо довга причина")))
ok("Клієнт відкриває спір", R(A, TR, (O4, "disputed", "Роботу не виконано вчасно")))
check("Створено рівно один відкритий спір",
      sup("select count(*) from order_disputes where order_id=%s and resolved_at is null", (O4,))[0][0] == 1)
err("Повторно оскаржити вже спірне не можна", R(B, TR, (O4, "disputed", "ще одна причина тут")))
rows("Адмін бачить спірне замовлення", R(E, "select id from orders where id=%s", (O4,)), 1)
rows("Адмін читає чат спірного замовлення", R(E, "select id from messages where order_id=%s", (O4,)), 2)
rows("Адмін бачить журнал спору", R(E, "select id from order_events where order_id=%s", (O4,)), sup("select count(*) from order_events where order_id=%s", (O4,))[0][0])
rows("Адмін бачить зустрічі спору", R(E, "select id from meetings where order_id=%s", (O4,)), sup("select count(*) from meetings where order_id=%s", (O4,))[0][0])
err("Адмін не пише в чат (лише читає)", R(E, MS, (O4, E, "рішення")))
err("Адмін не змінює статус напряму", R(E, "update orders set status='completed' where id=%s", (O4,)))
err("Адмін не редагує поля замовлення", R(E, "update orders set budget=1 where id=%s", (O4,)))
err("Не-адмін не розв'язує спір", R(A, "select * from resolve_order_dispute(%s,'completed','дуже довге рішення')", (O4,)))
err("Виконавець не розв'язує спір", R(B, "select * from resolve_order_dispute(%s,'completed','дуже довге рішення')", (O4,)))
err("Адмін: коротке рішення відхиляється", R(E, "select * from resolve_order_dispute(%s,'completed','ні')", (O4,)))
err("Адмін: невалідний підсумок відхиляється", R(E, "select * from resolve_order_dispute(%s,'draft','достатньо довге рішення')", (O4,)))
err("Анонім не викликає арбітраж", R(None, "select * from resolve_order_dispute(%s,'completed','достатньо довге')", (O4,), role="anon"))
ok("Адмін розв'язує спір", R(E, "select * from resolve_order_dispute(%s,'in_progress','Перевірено: роботу продовжити')", (O4,)))
d = sup("select resolution, resolved_by, resolved_at is not null from order_disputes where order_id=%s", (O4,))[0]
check("Рішення, автор і час записані у спір", d[0] == "Перевірено: роботу продовжити" and str(d[1]) == E and d[2], d)
check("Подія dispute_resolved записана",
      sup("select count(*) from order_events where order_id=%s and event_type='dispute_resolved'", (O4,))[0][0] == 1)
check("Замовлення повернулось у in_progress", sup("select status from orders where id=%s", (O4,))[0][0] == "in_progress")
rows("Після рішення адмін більше не бачить замовлення", R(E, "select id from orders where id=%s", (O4,)), 0)
rows("Після рішення адмін не читає чат", R(E, "select id from messages where order_id=%s", (O4,)), 0)
err("Повторно розв'язати нічого", R(E, "select * from resolve_order_dispute(%s,'completed','достатньо довге рішення')", (O4,)))
ok("Спір можна відкрити вдруге після розв'язання", R(B, TR, (O4, "disputed", "Клієнт не відповідає на повідомлення")))
ok("Адмін закриває другий спір (cancelled)", R(E, "select * from resolve_order_dispute(%s,'cancelled','Скасовано за згодою сторін')", (O4,)))

sec("11. Файли (Storage)")
sup("update orders set created_at = created_at - interval '1 hour'")
r0 = R(A, INS, (A, B)); O7 = r0[1][0][0]
for who, st in ((A, "requested"), (B, "accepted")):
    R(who, TR, (O7, st, None))
SI = "insert into storage.objects(bucket_id,name) values (%s,%s)"
ok("Клієнт завантажує файл у папку замовлення", R(A, SI, ("order-files", f"{O7}/{uuid.uuid4()}-mix.wav")))
ok("Виконавець завантажує файл у папку замовлення", R(B, SI, ("order-files", f"{O7}/{uuid.uuid4()}-stem.wav")))
err("Сторонній не завантажує у чуже замовлення", R(D, SI, ("order-files", f"{O7}/{uuid.uuid4()}-x.wav")))
err("Адмін не завантажує файли", R(E, SI, ("order-files", f"{O7}/{uuid.uuid4()}-x.wav")))
err("Файл у корені бакета (без папки замовлення) відхиляється", R(A, SI, ("order-files", "orphan.wav")))
err("Інший бакет без політики відхиляється", R(A, SI, ("avatars", f"{O7}/x.png")))
rows("Учасник бачить файли замовлення", R(A, "select id from storage.objects where bucket_id='order-files'", None), 2)
rows("Сторонній не бачить файли", R(D, "select id from storage.objects where bucket_id='order-files'", None), 0)
r = R(A, "delete from storage.objects where bucket_id='order-files'")
T.append((SEC[0], "Файли не можна видаляти з клієнта", r[0] == "err" or n(r[1]) == 0, r))
r = R(A, "update storage.objects set name='x' where bucket_id='order-files'")
T.append((SEC[0], "Файли не можна перейменовувати з клієнта", r[0] == "err" or n(r[1]) == 0, r))
bk = sup("select public, file_size_limit from storage.buckets where id='order-files'")[0]
check("Бакет приватний, ліміт файлу 50 МБ", bk == (False, 52428800), bk)

sec("12. Ліміти (захист від спаму)")
for i in range(5):
    R(G, INS, (G, B))
err("6-те замовлення за 10 хв відхиляється (rate limit)", R(G, INS, (G, B)), "rate limit")
r = R(G, INS, (G, B)) if False else None
oidg = sup("select id from orders where client_id=%s limit 1", (G,))[0][0]
sup("update orders set status='requested' where id=%s", (oidg,))
sup("update orders set status='accepted' where id=%s", (oidg,))
good = sum(1 for i in range(30) if R(G, MS, (oidg, G, f"m{i}"))[0] == "ok")
check("30 повідомлень за хвилину проходять", good == 30, good)
err("31-ше повідомлення за хвилину відхиляється", R(G, MS, (oidg, G, "перебір")), "rate limit")

sec("13. Анонім та доступ до функцій")
for t in ("orders", "messages", "meetings", "order_events", "order_disputes", "order_deliverables", "profiles"):
    err(f"Анонім не читає {t}", R(None, f"select * from {t}", role="anon"))
err("Анонім не викликає transition_order", R(None, TR, (O1, "requested", None), role="anon"))
err("Анонім не викликає create_meeting", R(None, CM, (O4, "remote", None, None, "https://meet.jit.si/x"), role="anon"))
err("Анонім не викликає is_soundcollab_admin", R(None, "select is_soundcollab_admin()", role="anon"))
check("Звичайний користувач не адмін за is_soundcollab_admin()", R(A, "select is_soundcollab_admin()")[1][0][0] is False)
check("Адмін визначається через is_soundcollab_admin()", R(E, "select is_soundcollab_admin()")[1][0][0] is True)

# ------------------------------------------------------------------ audits
sec("14. Аудит прав у базі")
funcs = sup("""select p.proname, has_function_privilege('anon', p.oid, 'execute'),
               has_function_privilege('authenticated', p.oid, 'execute'), p.prosecdef, p.proconfig::text
               from pg_proc p join pg_namespace n on n.oid=p.pronamespace
               where n.nspname='public' and p.prokind='f' and p.prorettype <> 'trigger'::regtype
               and not exists (select 1 from pg_depend d where d.objid=p.oid and d.deptype='e') order by 1""")
print("\n== ФУНКЦІЇ public (не тригерні): anon / authenticated / security definer / search_path")
for f in funcs:
    print(f"   {f[0]:32} anon={f[1]!s:5} auth={f[2]!s:5} definer={f[3]!s:5} path={'ok' if f[4] and 'search_path' in f[4] else 'НЕМАЄ'}")
check("Жодна публічна не-тригерна функція не доступна для anon", not any(f[1] for f in funcs), [f[0] for f in funcs if f[1]])
check("Усі SECURITY DEFINER функції мають фіксований search_path",
      all((not f[3]) or (f[4] and "search_path" in f[4]) for f in funcs), [f[0] for f in funcs if f[3] and not (f[4] and "search_path" in f[4])])
ext = sup("select e.extname from pg_extension e join pg_namespace n on n.oid=e.extnamespace where n.nspname='public' and e.extname <> 'plpgsql'")
check("Розширення не встановлені в схемі public (їхні функції доступні anon через API)", not ext, [x[0] for x in ext])
trig = sup("""select p.proname, has_function_privilege('anon', p.oid,'execute'), has_function_privilege('authenticated', p.oid,'execute'), p.prosecdef, p.proconfig::text
              from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.prorettype='trigger'::regtype""")
check("SECURITY DEFINER тригерні функції мають фіксований search_path",
      all((not f[3]) or (f[4] and "search_path" in f[4]) for f in trig), [f[0] for f in trig if f[3] and not (f[4] and "search_path" in f[4])])
grants = sup("""select table_name, grantee, string_agg(privilege_type, ',' order by privilege_type)
                from information_schema.role_table_grants where table_schema='public' and grantee in ('anon','authenticated')
                group by 1,2 order by 1,2""")
print("\n== ПРАВА НА ТАБЛИЦІ (public)")
for g in grants:
    print(f"   {g[0]:20} {g[1]:14} {g[2]}")
check("anon не має жодних прав на таблиці public", not any(g[1] == "anon" for g in grants), [g for g in grants if g[1] == "anon"])
for tbl in ("order_events", "messages", "meetings", "order_disputes"):
    bad = [g for g in grants if g[0] == tbl and g[1] == "authenticated" and ("UPDATE" in g[2] or "DELETE" in g[2])]
    check(f"authenticated не має UPDATE/DELETE на {tbl}", not bad, bad)
pol = sup("select tablename, count(*) from pg_policies where schemaname in ('public','storage') group by 1 order by 1")
print("\n== ПОЛІТИКИ RLS:", ", ".join(f"{p[0]}={p[1]}" for p in pol))
nopol = sup("""select c.relname from pg_class c where c.relnamespace='public'::regnamespace and c.relkind='r'
               and c.relrowsecurity and not exists (select 1 from pg_policies p where p.schemaname='public' and p.tablename=c.relname)""")
print("   таблиці з RLS, але без жодної політики (повністю закриті):", [x[0] for x in nopol] or "немає")

# ------------------------------------------------------------------ report
passed = sum(1 for t in T if t[2])
print(f"\n{'=' * 70}\nПІДСУМОК: {passed}/{len(T)} перевірок пройдено\n{'=' * 70}")
cur_sec = None
for s, name, p, d in T:
    if s != cur_sec:
        cur_sec = s
        sp = sum(1 for t in T if t[0] == s and t[2]); st = sum(1 for t in T if t[0] == s)
        print(f"\n[{s}]  {sp}/{st}")
    if not p:
        print(f"   ✗ {name}\n        → {str(d)[:230]}")
print()
sys.exit(0 if passed == len(T) else 1)
