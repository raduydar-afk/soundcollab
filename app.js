const createClient = window.supabase?.createClient;
const SUPABASE_URL = window.SOUNDCOLLAB_SUPABASE_URL;
const SUPABASE_ANON_KEY = window.SOUNDCOLLAB_SUPABASE_ANON_KEY;
const configured = typeof createClient === "function" && Boolean(
  SUPABASE_URL?.startsWith("https://")
    && !SUPABASE_URL.includes("YOUR_PROJECT_ID")
    && SUPABASE_ANON_KEY
    && !SUPABASE_ANON_KEY.includes("YOUR_PUBLIC_ANON_KEY"),
);
const supabase = configured
  ? createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      auth: { autoRefreshToken: true, persistSession: true, detectSessionInUrl: true },
    })
  : null;

const STATUS_LABELS = {
  draft: "Чернетка",
  requested: "Запитано",
  accepted: "Прийнято",
  declined: "Відхилено",
  in_progress: "У роботі",
  delivered: "Здано",
  completed: "Завершено",
  cancelled: "Скасовано",
  disputed: "Спір",
  proposed: "Запропоновано",
  confirmed: "Підтверджено",
  rescheduled: "Запропоновано інший час",
};

const $ = (selector, parent = document) => parent.querySelector(selector);
const $$ = (selector, parent = document) => [...parent.querySelectorAll(selector)];
const escapeHTML = (value) => String(value ?? "").replace(/[&<>"']/g, (char) => ({
  "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
})[char]);
const formatDate = (value) => {
  if (!value) return "Без дедлайну";
  const date = new Date(value);
  return Number.isNaN(date.valueOf()) ? "Дата не вказана" : date.toLocaleString("uk-UA", { dateStyle: "medium", timeStyle: value.includes("T") ? "short" : undefined });
};
const messageForError = (error) => error?.message || "Не вдалося виконати запит. Перевірте з’єднання й налаштування Supabase.";
const setMessage = (selector, value, isError = false) => {
  const target = $(selector);
  if (!target) return;
  target.textContent = value;
  target.classList.toggle("is-error", isError);
};
const setNotice = (text, isError = false) => {
  const notice = $("#app-notice");
  if (!notice) return;
  notice.textContent = text;
  notice.classList.toggle("is-error", isError);
};
const redirectTarget = () => {
  const target = new URLSearchParams(location.search).get("redirect");
  if (["client.html", "specialist.html", "index.html"].includes(target)) return target;
  if (/^order\.html\?id=[0-9a-f-]{36}$/i.test(target || "")) return target;
  return "";
};
const currentProfile = async (user) => {
  const { data, error } = await supabase.from("profiles")
    .select("id,display_name,roles,bio,city,portfolio")
    .eq("id", user.id).single();
  if (error) throw error;
  const { data: isAdmin, error: adminError } = await supabase.rpc("is_soundcollab_admin");
  if (adminError) throw adminError;
  return { ...data, is_admin: isAdmin };
};
const statusText = (status) => STATUS_LABELS[status] || status;
const safeHttpsUrl = (value) => {
  try {
    const parsed = new URL(value);
    return ["https:", "http:"].includes(parsed.protocol) ? parsed.href : "";
  } catch {
    return "";
  }
};

function renderOrderCard(order, otherName = "") {
  const target = `order.html?id=${encodeURIComponent(order.id)}`;
  const budget = Number(order.budget).toLocaleString("uk-UA");
  return `<article class="app-order-card">
    <div class="app-order-card-head"><div><p class="eyebrow">${escapeHTML(order.service)}</p><h3>${escapeHTML(order.title)}</h3></div><span class="status-badge status-${escapeHTML(order.status)}">${escapeHTML(statusText(order.status))}</span></div>
    <p>${escapeHTML(order.description)}</p>
    <div class="app-order-meta"><span>${otherName ? `Учасник: ${escapeHTML(otherName)}` : "Замовлення SoundCollab"}</span><span>₴ ${escapeHTML(budget)}</span><span>До: ${escapeHTML(formatDate(order.deadline))}</span><span>${order.format === "remote" ? "Дистанційно" : "Особиста зустріч"}</span></div>
    <a class="button button-small button-primary" href="${target}">Відкрити замовлення →</a>
  </article>`;
}

async function getProfilesById(ids) {
  const uniqueIds = [...new Set(ids.filter(Boolean))];
  if (!uniqueIds.length) return {};
  const { data, error } = await supabase.from("profiles").select("id,display_name,city").in("id", uniqueIds);
  if (error) throw error;
  return Object.fromEntries(data.map((profile) => [profile.id, profile]));
}

async function loadAdminDisputes(profile) {
  if (!$("#admin-disputes") || !profile.is_admin) return;
  $("#admin-disputes").hidden = false;
  const { data, error } = await supabase.from("orders").select("*").eq("status", "disputed")
    .order("updated_at", { ascending: false });
  if (error) throw error;
  const people = await getProfilesById(data.flatMap((order) => [order.client_id, order.performer_id]));
  $("#admin-disputes-list").innerHTML = data.length
    ? data.map((order) => renderOrderCard(order, people[order.client_id]?.display_name || "Клієнт")).join("")
    : "<p class='empty-state'>Відкритих спорів немає.</p>";
}

async function loadClientDashboard(user, profile) {
  const shell = $("#client-app");
  if (!shell) return;
  loadAdminDisputes(profile).catch((error) => setNotice(`Не вдалося завантажити список спорів: ${messageForError(error)}`, true));
  if (!profile.roles.includes("client") && !profile.is_admin) {
    setNotice("У профілі не активована роль замовника. Змініть ролі в акаунті або увійдіть під іншим користувачем.", true);
    return;
  }
  shell.hidden = false;
  if (!profile.roles.includes("client")) {
    $$("#client-app > .dash-toolbar, #order-create-form, #client-orders").forEach((element) => { element.hidden = true; });
  }
  $("#client-greeting").textContent = profile.display_name ? `Вітаємо, ${profile.display_name}` : user.email;
  const performerSelect = $('#order-create-form select[name="performer_id"]');
  const refresh = async () => {
    const { data: orders, error } = await supabase.from("orders").select("*")
      .eq("client_id", user.id).order("created_at", { ascending: false });
    if (error) throw error;
    const profiles = await getProfilesById(orders.map((order) => order.performer_id));
    $("#client-orders").innerHTML = orders.length
      ? orders.map((order) => renderOrderCard(order, profiles[order.performer_id]?.display_name || "Очікує виконавця")).join("")
      : '<div class="app-panel"><p>Замовлень ще немає. Створи перший запит вище.</p></div>';
  };
  const loadPerformers = async () => {
    const { data, error } = await supabase.from("profiles").select("id,display_name,city")
      .contains("roles", ["performer"]).neq("id", user.id).order("display_name");
    if (error) throw error;
    performerSelect.insertAdjacentHTML("beforeend", data.map((person) =>
      `<option value="${escapeHTML(person.id)}">${escapeHTML(person.display_name)}${person.city ? ` · ${escapeHTML(person.city)}` : ""}</option>`,
    ).join(""));
  };
  try {
    await Promise.all([refresh(), loadPerformers()]);
  } catch (error) {
    setNotice(`Не вдалося завантажити дані кабінету: ${messageForError(error)}`, true);
  }
  $("[data-refresh]")?.addEventListener("click", () => refresh().catch((error) => setNotice(messageForError(error), true)));
  $("#order-create-form")?.addEventListener("submit", async (event) => {
    event.preventDefault();
    const form = event.currentTarget;
    const data = new FormData(form);
    const button = $('button[type="submit"]', form);
    button.disabled = true;
    setMessage("#create-order-message", "Створюємо чернетку та надсилаємо запит…");
    try {
      const { data: created, error } = await supabase.from("orders").insert({
        client_id: user.id,
        performer_id: data.get("performer_id") || null,
        service: data.get("service"),
        title: data.get("title").trim(),
        description: data.get("description").trim(),
        budget: Number(data.get("budget")),
        format: data.get("format"),
        deadline: data.get("deadline") || null,
        status: "draft",
      }).select("id").single();
      if (error) throw error;
      const { error: transitionError } = await supabase.rpc("transition_order", {
        target_order: created.id, target_status: "requested", reason: null,
      });
      if (transitionError) {
        setMessage("#create-order-message", `Чернетку створено, але запит не надіслано: ${messageForError(transitionError)} Відкрийте її та повторіть дію.`, true);
      } else {
        form.reset();
        setMessage("#create-order-message", "Запит надіслано. Нове замовлення з’явиться у списку.");
      }
      await refresh();
    } catch (error) {
      setMessage("#create-order-message", messageForError(error), true);
    } finally {
      button.disabled = false;
    }
  });
}

async function loadSpecialistDashboard(user, profile) {
  const shell = $("#specialist-app");
  if (!shell) return;
  loadAdminDisputes(profile).catch((error) => setNotice(`Не вдалося завантажити список спорів: ${messageForError(error)}`, true));
  if (!profile.roles.includes("performer") && !profile.is_admin) {
    setNotice("У профілі не активована роль виконавця. Зареєструйтеся з цією роллю або увійдіть під іншим користувачем.", true);
    return;
  }
  shell.hidden = false;
  const form = $("#performer-profile-form");
  if (!profile.roles.includes("performer")) {
    $$("#performer-profile-form, #specialist-app > .dash-toolbar, #specialist-orders").forEach((element) => { element.hidden = true; });
    return;
  }
  const portfolio = Array.isArray(profile.portfolio) ? profile.portfolio : [];
  form.elements.display_name.value = profile.display_name || "";
  form.elements.city.value = profile.city || "";
  form.elements.bio.value = profile.bio || "";
  form.elements.portfolio_url.value = portfolio[0]?.url || "";
  const refresh = async () => {
    const { data: orders, error } = await supabase.from("orders").select("*")
      .or(`performer_id.eq.${user.id},and(status.eq.requested,performer_id.is.null)`)
      .order("created_at", { ascending: false });
    if (error) throw error;
    const people = await getProfilesById(orders.map((order) => order.client_id));
    $("#specialist-orders").innerHTML = orders.length ? orders.map((order) => {
      const action = order.status === "requested"
        ? `<div class="inline-actions"><button class="button button-small button-primary" type="button" data-transition="accepted" data-order="${escapeHTML(order.id)}">Прийняти</button>${order.performer_id ? `<button class="button button-small button-light" type="button" data-transition="declined" data-order="${escapeHTML(order.id)}">Відхилити</button>` : ""}</div>`
        : order.status === "accepted"
          ? `<button class="button button-small button-primary" type="button" data-transition="in_progress" data-order="${escapeHTML(order.id)}">Почати роботу</button>`
          : "";
      return `${renderOrderCard(order, people[order.client_id]?.display_name || "Клієнт")}${action ? `<div class="app-order-actions">${action}</div>` : ""}`;
    }).join("") : '<div class="app-panel"><p>Поки немає вхідних запитів або призначених замовлень.</p></div>';
    $$("[data-transition]").forEach((button) => button.addEventListener("click", async () => {
      button.disabled = true;
      const { error: transitionError } = await supabase.rpc("transition_order", {
        target_order: button.dataset.order, target_status: button.dataset.transition, reason: null,
      });
      if (transitionError) setNotice(`Не вдалося оновити замовлення: ${messageForError(transitionError)}`, true);
      else setNotice(`Статус змінено на «${statusText(button.dataset.transition)}».`);
      await refresh().catch((error) => setNotice(messageForError(error), true));
    }));
  };
  try {
    await refresh();
  } catch (error) {
    setNotice(`Не вдалося завантажити замовлення: ${messageForError(error)}`, true);
  }
  $("[data-refresh]")?.addEventListener("click", () => refresh().catch((error) => setNotice(messageForError(error), true)));
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const data = new FormData(form);
    const rawUrl = data.get("portfolio_url").trim();
    const portfolioUrl = rawUrl ? safeHttpsUrl(rawUrl) : "";
    if (rawUrl && !portfolioUrl) {
      setMessage("#profile-message", "Посилання портфоліо має починатися з http:// або https://.", true);
      return;
    }
    const roles = [...new Set([...profile.roles, "performer"])];
    const { error } = await supabase.from("profiles").update({
      display_name: data.get("display_name").trim(),
      city: data.get("city").trim(),
      bio: data.get("bio").trim(),
      portfolio: portfolioUrl ? [{ label: "Портфоліо", url: portfolioUrl }] : [],
      roles,
    }).eq("id", user.id);
    setMessage("#profile-message", error ? messageForError(error) : "Профіль збережено.", Boolean(error));
    if (!error) Object.assign(profile, { display_name: data.get("display_name").trim(), roles });
  });
}

async function handleAuthPage() {
  const loginForm = $("#login-form");
  const signupForm = $("#signup-form");
  if (!loginForm && !signupForm) return;

  const resetForm = $("#reset-form");
  const newPasswordForm = $("#new-password-form");
  const recovery = new URLSearchParams(location.search).get("view") === "update-password"
    || location.hash.includes("type=recovery");
  if (recovery && newPasswordForm) {
    loginForm.hidden = true;
    signupForm.hidden = true;
    resetForm.hidden = true;
    newPasswordForm.hidden = false;
  }
  if (!supabase) {
    $$("button[type='submit']").forEach((button) => { button.disabled = true; });
    return;
  }

  loginForm?.addEventListener("submit", async (event) => {
    event.preventDefault();
    const data = new FormData(loginForm);
    setMessage("#login-message", "Входимо…");
    const { data: result, error } = await supabase.auth.signInWithPassword({
      email: data.get("email").trim(), password: data.get("password"),
    });
    if (error) return setMessage("#login-message", messageForError(error), true);
    try {
      const profile = await currentProfile(result.user);
      const destination = redirectTarget()
        || (profile.roles.includes("client") ? "client.html" : "specialist.html");
      location.assign(destination);
    } catch (profileError) {
      setMessage("#login-message", `Увійшли, але профіль не завантажився: ${messageForError(profileError)}`, true);
    }
  });

  signupForm?.addEventListener("submit", async (event) => {
    event.preventDefault();
    const data = new FormData(signupForm);
    const roles = data.getAll("roles");
    if (!roles.length) return setMessage("#signup-message", "Оберіть хоча б одну роль.", true);
    if (data.get("privacy_consent") !== "on") return setMessage("#signup-message", "Потрібна згода з політикою конфіденційності.", true);
    setMessage("#signup-message", "Створюємо акаунт…");
    const callback = new URL("auth.html", location.href).href;
    const { data: result, error } = await supabase.auth.signUp({
      email: data.get("email").trim(),
      password: data.get("password"),
      options: {
        emailRedirectTo: callback,
        data: {
          display_name: data.get("display_name").trim(),
          roles,
          privacy_consent: true,
          privacy_policy_version: "2026-10-15",
        },
      },
    });
    if (error) return setMessage("#signup-message", messageForError(error), true);
    if (!result.session) {
      setMessage("#signup-message", "Акаунт створено. Перевірте пошту та підтвердіть email, потім увійдіть.");
      signupForm.reset();
      return;
    }
    location.assign(redirectTarget() || (roles.includes("client") ? "client.html" : "specialist.html"));
  });

  $("[data-show-reset]")?.addEventListener("click", () => {
    resetForm.hidden = !resetForm.hidden;
    if (!resetForm.hidden && loginForm.elements.email.value) resetForm.elements.email.value = loginForm.elements.email.value;
  });
  resetForm?.addEventListener("submit", async (event) => {
    event.preventDefault();
    const data = new FormData(resetForm);
    const redirectTo = new URL("auth.html?view=update-password", location.href).href;
    const { error } = await supabase.auth.resetPasswordForEmail(data.get("email").trim(), { redirectTo });
    setMessage("#reset-message", error ? messageForError(error) : "Якщо акаунт із цією адресою існує, ми надіслали посилання для відновлення.", Boolean(error));
  });
  newPasswordForm?.addEventListener("submit", async (event) => {
    event.preventDefault();
    const password = new FormData(newPasswordForm).get("password");
    const { error } = await supabase.auth.updateUser({ password });
    if (error) return setMessage("#new-password-message", messageForError(error), true);
    setMessage("#new-password-message", "Пароль оновлено. Поверніться до кабінету та увійдіть.");
    await supabase.auth.signOut();
  });
}

function statusActions(order, profile) {
  const actions = [];
  const assigned = order.performer_id === profile.id;
  const canAccept = profile.roles.includes("performer") && order.status === "requested"
    && (!order.performer_id || assigned);
  if (canAccept) {
    actions.push('<button class="button button-primary" type="button" data-order-transition="accepted">Прийняти замовлення</button>');
    if (order.performer_id) actions.push('<button class="button button-light" type="button" data-order-transition="declined">Відхилити</button>');
  }
  if (order.client_id === profile.id && order.status === "draft") {
    actions.push('<button class="button button-primary" type="button" data-order-transition="requested">Надіслати запит</button>');
  }
  if (assigned && order.status === "accepted") actions.push('<button class="button button-primary" type="button" data-order-transition="in_progress">Почати роботу</button>');
  if (order.status === "delivered" && order.client_id === profile.id) actions.push('<button class="button button-primary" type="button" data-order-transition="completed">Підтвердити завершення</button>');
  if (["draft", "requested", "accepted", "in_progress"].includes(order.status)
      && [order.client_id, order.performer_id].includes(profile.id)) {
    actions.push('<button class="button button-light" type="button" data-order-transition="cancelled">Скасувати замовлення</button>');
  }
  if (["requested", "accepted", "in_progress", "delivered"].includes(order.status)
      && [order.client_id, order.performer_id].includes(profile.id)) {
    actions.push('<form id="dispute-form" class="app-form dispute-form"><label>Причина спору<textarea name="reason" rows="2" required minlength="5" maxlength="2000"></textarea></label><button class="button button-accent" type="submit">Відкрити спір</button><p id="dispute-message" class="form-message" role="status"></p></form>');
  }
  return actions.join("");
}

async function loadOrderPage(user, profile) {
  if (!$("#order-workspace")) return;
  const orderId = new URLSearchParams(location.search).get("id");
  if (!orderId || !/^[0-9a-f-]{36}$/i.test(orderId)) {
    setNotice("Посилання на замовлення некоректне. Поверніться до кабінету й відкрийте замовлення зі списку.", true);
    return;
  }
  const { data: order, error } = await supabase.from("orders").select("*").eq("id", orderId).single();
  if (error) {
    setNotice(`Не вдалося відкрити замовлення: ${messageForError(error)}`, true);
    return;
  }
  const isParticipant = [order.client_id, order.performer_id].includes(user.id);
  if (!isParticipant && !profile.is_admin) {
    setNotice("Це приватне замовлення. Ваш акаунт не є його учасником.", true);
    return;
  }
  $("#order-workspace").hidden = false;
  $("#order-title").textContent = order.title;
  $("#order-subtitle").textContent = `${order.service} · ₴ ${Number(order.budget).toLocaleString("uk-UA")} · ${order.format === "remote" ? "дистанційно" : "особиста зустріч"} · дедлайн ${formatDate(order.deadline)}`;
  $("#order-status").textContent = statusText(order.status);
  $("#order-status").className = `status-badge status-${order.status}`;
  const people = await getProfilesById([order.client_id, order.performer_id]);
  $("#order-participants").textContent = `Клієнт: ${people[order.client_id]?.display_name || "Користувач"} · Виконавець: ${people[order.performer_id]?.display_name || "Ще не призначений"}`;
  $("#order-actions").innerHTML = statusActions(order, profile);
  if (profile.is_admin && order.status === "disputed") $("#admin-dispute").hidden = false;
  $("#meeting-form").hidden = !["accepted", "in_progress"].includes(order.status);
  $("#deliverable-form").hidden = order.performer_id !== user.id || order.status !== "in_progress";

  const reload = async () => {
    const { data: current, error: currentError } = await supabase.from("orders").select("*").eq("id", orderId).single();
    if (currentError) throw currentError;
    Object.assign(order, current);
    $("#order-title").textContent = current.title;
    $("#order-status").textContent = statusText(current.status);
    $("#order-status").className = `status-badge status-${current.status}`;
    $("#order-actions").innerHTML = statusActions(current, profile);
    $("#meeting-form").hidden = !["accepted", "in_progress"].includes(current.status);
    $("#deliverable-form").hidden = current.performer_id !== user.id || current.status !== "in_progress";
    bindOrderActionButtons();
    await Promise.all([loadMessages(), loadEvents(), loadMeetings(), loadDeliverables(), loadStoredFiles()]);
  };

  async function loadMessages() {
    const { data, error: queryError } = await supabase.from("messages").select("id,sender_id,body,created_at")
      .eq("order_id", orderId).order("created_at");
    if (queryError) throw queryError;
    $("#messages-list").innerHTML = data.map((item) =>
      `<li class="${item.sender_id === user.id ? "message-own" : ""}"><div><b>${escapeHTML(item.sender_id === user.id ? "Ви" : (people[item.sender_id]?.display_name || "Учасник"))}</b><time>${escapeHTML(formatDate(item.created_at))}</time></div><p>${escapeHTML(item.body)}</p></li>`,
    ).join("") || "<li class='empty-state'>Повідомлень ще немає.</li>";
    $("#messages-list").scrollTop = $("#messages-list").scrollHeight;
  }

  async function loadEvents() {
    const { data, error: queryError } = await supabase.from("order_events").select("id,actor_id,event_type,details,created_at")
      .eq("order_id", orderId).order("created_at", { ascending: false }).limit(100);
    if (queryError) throw queryError;
    $("#order-events").innerHTML = data.map((item) => {
      const detail = item.event_type === "status_changed"
        ? `Статус: ${statusText(item.details.from)} → ${statusText(item.details.to)}${item.details.reason ? ` · ${item.details.reason}` : ""}`
        : item.event_type === "meeting_proposed" || item.event_type === "meeting_updated"
          ? `Зустріч: ${item.details.status ? statusText(item.details.status) : "запропонована"} · ${formatDate(item.details.scheduled_at)}`
          : item.event_type === "dispute_resolved"
            ? `Спір розглянуто: ${statusText(item.details.decision)} · ${item.details.resolution}`
            : item.event_type === "order_created" ? "Замовлення створено" : item.event_type.replaceAll("_", " ");
      return `<li><time>${escapeHTML(formatDate(item.created_at))}</time><span>${escapeHTML(detail)}</span></li>`;
    }).join("") || "<li>Подій поки немає.</li>";
  }

  async function loadMeetings() {
    const { data, error: queryError } = await supabase.from("meetings").select("*")
      .eq("order_id", orderId).order("created_at", { ascending: false });
    if (queryError) throw queryError;
    $("#meetings-list").innerHTML = data.map((meeting) => {
      const map = safeHttpsUrl(meeting.map_url);
      const video = safeHttpsUrl(meeting.meeting_url);
      const actions = meeting.status === "proposed" && meeting.proposer_id !== user.id && isParticipant
        ? `<div class="inline-actions"><button class="button button-small button-primary" type="button" data-meeting-response="confirmed" data-meeting="${escapeHTML(meeting.id)}">Підтвердити</button><button class="button button-small button-light" type="button" data-meeting-response="declined" data-meeting="${escapeHTML(meeting.id)}">Відхилити</button><input aria-label="Новий час" type="datetime-local" data-reschedule="${escapeHTML(meeting.id)}"><button class="button button-small button-light" type="button" data-meeting-response="rescheduled" data-meeting="${escapeHTML(meeting.id)}">Запропонувати інший час</button></div>`
        : "";
      return `<article class="meeting-card"><div><strong>${meeting.meeting_type === "remote" ? "Дистанційна зустріч" : "Особиста зустріч"}</strong><span class="status-badge">${escapeHTML(statusText(meeting.status))}</span></div><p>${escapeHTML(formatDate(meeting.scheduled_at))}${meeting.location ? ` · ${escapeHTML(meeting.location)}` : ""}</p>${video ? `<a href="${escapeHTML(video)}" target="_blank" rel="noopener noreferrer">Відкрити посилання на кімнату</a>` : ""}${map ? `<a href="${escapeHTML(map)}" target="_blank" rel="noopener noreferrer">Відкрити карту</a>` : ""}${actions}</article>`;
    }).join("") || "<p class='empty-state'>Зустрічей ще не запропоновано.</p>";
    $$("[data-meeting-response]").forEach((button) => button.addEventListener("click", async () => {
      const response = button.dataset.meetingResponse;
      const input = $(`[data-reschedule="${button.dataset.meeting}"]`);
      const newStartsAt = response === "rescheduled" && input?.value ? new Date(input.value).toISOString() : null;
      if (response === "rescheduled" && !newStartsAt) {
        setMessage("#meeting-message", "Оберіть нову дату й час.", true);
        return;
      }
      button.disabled = true;
      const { error: rpcError } = await supabase.rpc("respond_to_meeting", {
        target_meeting: button.dataset.meeting, response, new_starts_at: newStartsAt,
      });
      if (rpcError) setMessage("#meeting-message", messageForError(rpcError), true);
      else setMessage("#meeting-message", `Відповідь на зустріч: ${statusText(response)}.`);
      await loadMeetings();
      await loadEvents();
    }));
  }

  async function loadDeliverables() {
    const { data, error: queryError } = await supabase.from("order_deliverables").select("*")
      .eq("order_id", orderId).order("created_at", { ascending: false });
    if (queryError) throw queryError;
    $("#deliverables-list").innerHTML = data.map((item) => {
      const link = safeHttpsUrl(item.link_url);
      return `<article class="deliverable-card"><time>${escapeHTML(formatDate(item.created_at))}</time>${link ? `<a href="${escapeHTML(link)}" target="_blank" rel="noopener noreferrer">Відкрити передане посилання</a>` : ""}${item.file_path ? `<span>Файл доступний у захищеному списку нижче.</span>` : ""}<p>${escapeHTML(item.note)}</p></article>`;
    }).join("") || "<p class='empty-state'>Результати ще не передані.</p>";
  }

  async function loadStoredFiles() {
    const { data, error: listError } = await supabase.storage.from("order-files").list(orderId, {
      limit: 100, sortBy: { column: "created_at", order: "desc" },
    });
    if (listError) throw listError;
    const files = data.filter((file) => file.name && !file.name.startsWith("."));
    const signed = await Promise.all(files.map(async (file) => {
      const path = `${orderId}/${file.name}`;
      const { data: link, error: signedError } = await supabase.storage.from("order-files").createSignedUrl(path, 300);
      if (signedError) throw signedError;
      return `<li><a href="${escapeHTML(link.signedUrl)}" target="_blank" rel="noopener noreferrer">${escapeHTML(file.name.replace(/^[0-9a-f-]{36}-/i, ""))}</a><small>Посилання діє 5 хвилин.</small></li>`;
    }));
    $("#order-files-list").innerHTML = signed.length ? `<h4>Захищені файли</h4><ul class="file-list">${signed.join("")}</ul>` : "";
  }

  function bindOrderActionButtons() {
    $$("[data-order-transition]").forEach((button) => button.addEventListener("click", async () => {
      if (button.dataset.orderTransition === "cancelled" && !confirm("Скасувати це замовлення?")) return;
      button.disabled = true;
      const { error: rpcError } = await supabase.rpc("transition_order", {
        target_order: orderId, target_status: button.dataset.orderTransition, reason: null,
      });
      if (rpcError) setNotice(`Не вдалося змінити статус: ${messageForError(rpcError)}`, true);
      else setNotice(`Замовлення оновлено: ${statusText(button.dataset.orderTransition)}.`);
      await reload().catch((reloadError) => setNotice(messageForError(reloadError), true));
    }));
    $("#dispute-form")?.addEventListener("submit", async (event) => {
      event.preventDefault();
      const reason = new FormData(event.currentTarget).get("reason").trim();
      const { error: rpcError } = await supabase.rpc("transition_order", {
        target_order: orderId, target_status: "disputed", reason,
      });
      if (rpcError) setMessage("#dispute-message", messageForError(rpcError), true);
      else {
        setMessage("#dispute-message", "Спір відкрито. Він доступний адміністраторам разом із чатом і журналом.");
        await reload();
      }
    });
  }

  bindOrderActionButtons();
  $("#message-form")?.addEventListener("submit", async (event) => {
    event.preventDefault();
    const form = event.currentTarget;
    const data = new FormData(form);
    const body = data.get("body").trim();
    if (!body) return;
    const { error: insertError } = await supabase.from("messages").insert({
      order_id: orderId, sender_id: user.id, body,
    });
    if (insertError) return setMessage("#message-status", messageForError(insertError), true);
    form.reset();
    setMessage("#message-status", "Повідомлення надіслано.");
    await loadMessages();
  });
  $("#meeting-form")?.addEventListener("submit", async (event) => {
    event.preventDefault();
    const data = new FormData(event.currentTarget);
    const type = data.get("meeting_type");
    const date = new Date(data.get("scheduled_at"));
    if (Number.isNaN(date.valueOf()) || date <= new Date()) return setMessage("#meeting-message", "Оберіть дату й час у майбутньому.", true);
    const meetingUrl = type === "remote" ? safeHttpsUrl(data.get("meeting_url")) : null;
    const mapUrl = type === "in_person" && data.get("map_url") ? safeHttpsUrl(data.get("map_url")) : null;
    if (type === "remote" && !meetingUrl) return setMessage("#meeting-message", "Додайте підтримуване HTTPS-посилання на зустріч.", true);
    if (data.get("map_url") && !mapUrl) return setMessage("#meeting-message", "Посилання на карту має бути HTTP(S).", true);
    const { error: rpcError } = await supabase.rpc("create_meeting", {
      target_order: orderId,
      meeting_kind: type,
      starts_at: date.toISOString(),
      place: type === "in_person" ? data.get("location").trim() : null,
      map_link: mapUrl,
      video_link: meetingUrl,
    });
    if (rpcError) return setMessage("#meeting-message", messageForError(rpcError), true);
    event.currentTarget.reset();
    setMessage("#meeting-message", "Пропозицію зустрічі надіслано учаснику для підтвердження.");
    await loadMeetings();
    await loadEvents();
  });
  $("#deliverable-form")?.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (order.performer_id !== user.id || order.status !== "in_progress") {
      setMessage("#deliverable-message", "Здати роботу може лише призначений виконавець у статусі «У роботі».", true);
      return;
    }
    const form = event.currentTarget;
    const data = new FormData(form);
    const rawLink = data.get("link_url").trim();
    const linkUrl = rawLink ? safeHttpsUrl(rawLink) : null;
    const file = data.get("file");
    if (rawLink && !linkUrl) return setMessage("#deliverable-message", "Посилання має бути HTTP(S).", true);
    if (!linkUrl && (!file || !file.size)) return setMessage("#deliverable-message", "Додайте посилання або файл.", true);
    if (file?.size > 50 * 1024 * 1024) return setMessage("#deliverable-message", "Файл завеликий: ліміт цього MVP — 50 МБ. Для аудіо передайте приватне посилання на файл.", true);
    let filePath = null;
    if (file?.size) {
      filePath = `${orderId}/${crypto.randomUUID()}-${file.name.replace(/[^a-zA-Z0-9._-]/g, "_")}`;
      const { error: uploadError } = await supabase.storage.from("order-files").upload(filePath, file, {
        contentType: file.type || "application/octet-stream", upsert: false,
      });
      if (uploadError) return setMessage("#deliverable-message", `Не вдалося завантажити файл: ${messageForError(uploadError)}`, true);
    }
    const { error: insertError } = await supabase.from("order_deliverables").insert({
      order_id: orderId, submitted_by: user.id, link_url: linkUrl, file_path: filePath,
      note: data.get("note").trim(),
    });
    if (insertError) return setMessage("#deliverable-message", `Файл завантажено, але результат не записано: ${messageForError(insertError)}`, true);
    const { error: transitionError } = await supabase.rpc("transition_order", {
      target_order: orderId, target_status: "delivered", reason: null,
    });
    if (transitionError) setMessage("#deliverable-message", `Результат збережено, але статус не оновлено: ${messageForError(transitionError)}`, true);
    else {
      setMessage("#deliverable-message", "Результат передано клієнту.");
      form.reset();
    }
    await reload();
  });
  $("#meeting-form select[name='meeting_type']")?.addEventListener("change", (event) => {
    const remote = event.currentTarget.value === "remote";
    $("[data-remote-fields]").hidden = !remote;
    $("[data-inperson-fields]").hidden = remote;
  });
  $("[data-create-jitsi]")?.addEventListener("click", () => {
    const roomId = crypto.randomUUID().replaceAll("-", "");
    $("#meeting-form input[name='meeting_url']").value = `https://meet.jit.si/SoundCollab-${roomId}`;
  });
  $("#admin-dispute")?.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!profile.is_admin) return;
    const data = new FormData(event.currentTarget);
    const { error: rpcError } = await supabase.rpc("resolve_order_dispute", {
      target_order: orderId,
      decision: data.get("decision"),
      resolution_text: data.get("resolution").trim(),
    });
    setMessage("#admin-message", rpcError ? messageForError(rpcError) : `Рішення зафіксовано: ${statusText(data.get("decision"))}.`, Boolean(rpcError));
    if (!rpcError) window.setTimeout(() => location.assign("client.html"), 1200);
  });
  await reload();
  supabase.channel(`order-messages-${orderId}`)
    .on("postgres_changes", {
      event: "INSERT", schema: "public", table: "messages", filter: `order_id=eq.${orderId}`,
    }, () => loadMessages().catch((error) => setNotice(messageForError(error), true)))
    .subscribe((state) => {
      if (state === "CHANNEL_ERROR" || state === "TIMED_OUT") setNotice("Realtime тимчасово недоступний. Оновіть сторінку, щоб перевірити чат.", true);
    });
}

async function init() {
  if (typeof createClient !== "function") {
    setNotice("Не вдалося завантажити локальну бібліотеку Supabase. Перевірте наявність vendor/supabase-js-2.117.3.js і повторіть спробу.", true);
    $$("button[type='submit']").forEach((button) => { button.disabled = true; });
    return;
  }
  if (!configured) {
    setNotice("Supabase не налаштований: скопіюйте URL і публічний anon key у supabase-config.js. Не додавайте service_role key.", true);
    $$("button[type='submit']").forEach((button) => { button.disabled = true; });
    return;
  }
  await handleAuthPage();
  const { data: sessionData, error } = await supabase.auth.getSession();
  if (error) {
    setNotice(`Не вдалося перевірити сесію: ${messageForError(error)}`, true);
    return;
  }
  const user = sessionData.session?.user;
  const signOutButtons = $$("[data-sign-out]");
  signOutButtons.forEach((button) => {
    button.hidden = !user;
    button.addEventListener("click", async () => {
      const { error: signOutError } = await supabase.auth.signOut();
      if (signOutError) setNotice(`Не вдалося вийти: ${messageForError(signOutError)}`, true);
      else location.assign("auth.html");
    });
  });
  if ($("#auth-required")) $("#auth-required").hidden = Boolean(user);
  if (!user) {
    if ($("#order-workspace")) {
      const orderId = new URLSearchParams(location.search).get("id");
      const login = $("a", $("#auth-required"));
      if (login && orderId) login.href = `auth.html?redirect=${encodeURIComponent(`order.html?id=${orderId}`)}`;
    }
    if ($("#app-notice")) setNotice("Ви не увійшли. Для захищених розділів використайте акаунт.");
    return;
  }
  setNotice(`Ви увійшли як ${user.email}.`);
  let profile;
  try {
    profile = await currentProfile(user);
  } catch (profileError) {
    setNotice(`Не вдалося завантажити профіль: ${messageForError(profileError)}`, true);
    return;
  }
  const authCallback = location.hash.includes("access_token") || location.hash.includes("type=signup");
  const passwordRecovery = new URLSearchParams(location.search).get("view") === "update-password";
  if ($("#signup-form") && authCallback && !passwordRecovery) {
    location.assign(redirectTarget() || (profile.roles.includes("client") ? "client.html" : "specialist.html"));
    return;
  }
  await Promise.all([
    loadClientDashboard(user, profile),
    loadSpecialistDashboard(user, profile),
    loadOrderPage(user, profile),
  ]);
}

init().catch((error) => setNotice(`Помилка застосунку: ${messageForError(error)}`, true));
