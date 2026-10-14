const menuButton = document.querySelector(".menu-toggle");
const mobileNav = document.querySelector("#mobile-nav");

menuButton?.addEventListener("click", () => {
  const isOpen = mobileNav.classList.toggle("open");
  menuButton.setAttribute("aria-expanded", String(isOpen));
});

mobileNav?.querySelectorAll("a").forEach((link) => {
  link.addEventListener("click", () => {
    mobileNav.classList.remove("open");
    menuButton?.setAttribute("aria-expanded", "false");
  });
});

document.querySelector("#request-form")?.addEventListener("submit", (event) => {
  event.preventDefault();
  const form = event.currentTarget;
  const service = new FormData(form).get("service");
  const message = document.querySelector("#form-message");
  if (!service || service === "Оберіть послугу") {
    message.textContent = "Оберіть послугу, щоб продовжити.";
    return;
  }
  const subject = encodeURIComponent(`Запит SoundCollab: ${service}`);
  const body = encodeURIComponent("Привіт! Хочу обговорити проєкт через SoundCollab.\n\nДеталі запиту:\n");
  message.textContent = "Готово — відкриваємо поштовий клієнт для безпечного демо-запиту.";
  window.setTimeout(() => {
    window.location.href = `mailto:sound.collab.official@gmail.com?subject=${subject}&body=${body}`;
  }, 350);
});

document.querySelector("#contact-form")?.addEventListener("submit", (event) => {
  event.preventDefault();
  const form = event.currentTarget;
  const data = new FormData(form);
  const message = document.querySelector("#contact-message");
  const service = data.get("service");
  if (!service) {
    message.textContent = "Оберіть напрямок, щоб сформувати запит.";
    return;
  }
  const subject = encodeURIComponent(`SoundCollab — ${service}`);
  const body = encodeURIComponent(
    `Ім'я: ${data.get("name")}\nEmail: ${data.get("email")}\nПослуга: ${service}\n\nБриф:\n${data.get("brief")}`,
  );
  message.textContent = "Готово — відкриваємо ваш поштовий клієнт.";
  window.setTimeout(() => {
    window.location.href = `mailto:sound.collab.official@gmail.com?subject=${subject}&body=${body}`;
  }, 350);
});

document.querySelector("[data-demo-action='status']")?.addEventListener("click", () => {
  const message = document.querySelector("#demo-message");
  message.textContent = "Демо: статус оновлено локально. У production це збереже зміни в order workspace.";
});
