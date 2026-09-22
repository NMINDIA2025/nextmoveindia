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

  if (!form) return;

  // Validate required fields.
  if (!form.checkValidity()) {
    form.reportValidity();
    return;
  }

  const parentName = document.getElementById('parentName')?.value.trim() || '';
  const phone = document.getElementById('phoneNumber')?.value.trim() || '';
  const childName = document.getElementById('childName')?.value.trim() || '';
  const age = document.getElementById('childAge')?.value || '';
  const city = document.getElementById('cityName')?.value.trim() || '';
  const goal = document.getElementById('learningGoal')?.value || 'Not specified';

  if (typeof gtag === 'function') {
    gtag('event', 'generate_lead', {
      event_category: 'lead',
      lead_type: 'free_demo',
      learning_goal: goal,
      child_age: age,
      city: city
    });
  }

  // Send the lead to the EXISTING Next Move India Apps Script.
  // no-cors is intentional because the site is hosted separately.
  const formData = new FormData(form);
  formData.append('formType', 'demo');

  fetch('https://script.google.com/macros/s/AKfycbx7l_O_wTLCANdUHs3bbd0p_ChBSFQY64PQYDX64fDA3U49ubzlvMDyEYtirORBzpGb7g/exec', {
    method: 'POST',
    mode: 'no-cors',
    body: formData
  }).catch(function(err) {
    console.error('Lead capture failed:', err);
  });

  // Show confirmation.
  form.style.display = 'none';
  if (success) success.style.display = 'block';

  // Open WhatsApp with the submitted details.
  const msg = encodeURIComponent(
    'Hi! I just submitted the NextMove India FREE Demo enquiry.\n' +
    'Parent: ' + parentName + '\n' +
    'Child: ' + childName + '\n' +
    'Age: ' + age + '\n' +
    'Goal: ' + goal + '\n' +
    'WhatsApp: ' + phone + '\n' +
    'Please help me with the next available demo slot.'
  );

  const waUrl = 'https://wa.me/919682420506?text=' + msg;

  // Open immediately so browser popup blockers are less likely to interfere.
  window.open(waUrl, '_blank', 'noopener,noreferrer');
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


// ===== LEAD CTA ANALYTICS =====
document.addEventListener('click', (e) => {
  const link = e.target.closest('a');
  if (!link || typeof gtag !== 'function') return;
  const href = link.getAttribute('href') || '';
  if (href.includes('wa.me')) gtag('event', 'whatsapp_click', { event_category: 'lead', link_text: (link.textContent || '').trim().slice(0,80) });
  if (href.includes('#demo-form')) gtag('event', 'demo_cta_click', { event_category: 'lead', link_text: (link.textContent || '').trim().slice(0,80) });
});
