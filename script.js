// ===== MOBILE MENU =====
const hamburger = document.getElementById('hamburger');
const mobileMenu = document.getElementById('mobileMenu');

if (hamburger && mobileMenu) {
  hamburger.addEventListener('click', () => {
    mobileMenu.classList.toggle('open');
    hamburger.innerHTML = mobileMenu.classList.contains('open') ? '✕' : '&#9776;';
  });
  // Close on link click
  mobileMenu.querySelectorAll('a').forEach(link => {
    link.addEventListener('click', () => {
      mobileMenu.classList.remove('open');
      hamburger.innerHTML = '&#9776;';
    });
  });
}

// ===== FAQ TOGGLE =====
function toggleFaq(btn) {
  const answer = btn.nextElementSibling;
  const allAnswers = document.querySelectorAll('.faq-a');
  const allBtns = document.querySelectorAll('.faq-q');

  // Close others
  allAnswers.forEach((a, i) => {
    if (a !== answer) {
      a.classList.remove('open');
      allBtns[i].classList.remove('open');
    }
  });

  answer.classList.toggle('open');
  btn.classList.toggle('open');
}

// ===== FORM SUBMIT =====
function handleFormSubmit(e) {
  e.preventDefault();
  const form = document.getElementById('bookingForm');
  const success = document.getElementById('formSuccess');

  // Get phone for WhatsApp redirect
  const phone = form.querySelector('input[type=tel]').value || '';
  const name = form.querySelector('input[type=text]').value || '';
  const childName = form.querySelectorAll('input[type=text]')[1]?.value || '';
  const age = form.querySelector('select')?.value || '';

  if (form) form.style.display = 'none';
  if (success) success.style.display = 'block';

  // Auto-open WhatsApp after 1 second
  const msg = encodeURIComponent(
    `Hi! I just booked a FREE Demo Class on the website.\nParent: ${name}\nChild: ${childName}\nAge: ${age}\nPlease confirm my slot!`
  );
  setTimeout(() => {
    window.open(`https://wa.me/919682420506?text=${msg}`, '_blank');
  }, 1200);
}

// ===== SCROLL ANIMATIONS =====
const observerOptions = {
  threshold: 0.1,
  rootMargin: '0px 0px -40px 0px'
};

const observer = new IntersectionObserver((entries) => {
  entries.forEach(entry => {
    if (entry.isIntersecting) {
      entry.target.style.opacity = '1';
      entry.target.style.transform = 'translateY(0)';
    }
  });
}, observerOptions);

// Apply fade-in to cards
document.addEventListener('DOMContentLoaded', () => {
  const animateEls = document.querySelectorAll(
    '.problem-card, .help-card, .testimonial-card, .safety-card, .value-card, .team-card, .program-card, .curr-card'
  );
  animateEls.forEach((el, i) => {
    el.style.opacity = '0';
    el.style.transform = 'translateY(20px)';
    el.style.transition = `opacity 0.5s ease ${i * 0.07}s, transform 0.5s ease ${i * 0.07}s`;
    observer.observe(el);
  });
});

// ===== NAVBAR SCROLL SHADOW =====
const navbar = document.querySelector('.navbar');
if (navbar) {
  window.addEventListener('scroll', () => {
    if (window.scrollY > 20) {
      navbar.style.boxShadow = '0 4px 24px rgba(255,107,53,0.15)';
    } else {
      navbar.style.boxShadow = '0 2px 16px rgba(255,107,53,0.08)';
    }
  });
}
