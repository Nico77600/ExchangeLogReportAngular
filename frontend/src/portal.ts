import { Component, inject, signal } from '@angular/core';
import { RouterOutlet } from '@angular/router';
import { Api, errorText } from './api';
@Component({
  selector: 'app-root', standalone: true, imports: [RouterOutlet],
  template: `
      <main class="report-shell">
        <div class="report-tools"><span class="scope-badge"><span class="status-dot"></span> Local read-only / private pilot 0.3.0</span>
          <div class="header-actions"><button type="button" (click)="toggle()">{{ dark() ? 'Light theme' : 'Dark theme' }}</button><button type="button" (click)="stop()">Stop portal</button></div>
        </div>
        @if (message()) { <div class="notice" role="status">{{ message() }}</div> }
        <router-outlet />
        <footer class="disclaimer"><p>Exchange Log Report / Nicolas Fabert. Private Angular pilot. Usage HTML remains available separately. No upload or Exchange changes. Never share the access token.</p><br>This Script is a Personal project.<br>It's provided "AS-IS". It's not an official Microsoft product so no support can be expected from Microsoft.<br><br>As any scripts you must read carefully the documentation and test it first in a Test environment before any run in Production.</footer>
      </main>`
})
export class AppComponent {
  private readonly api = inject(Api);
  readonly dark = signal(document.documentElement.getAttribute('data-theme') === 'dark');
  readonly message = signal('');
  toggle(): void { this.dark.update(value => !value); document.documentElement.setAttribute('data-theme', this.dark() ? 'dark' : 'light'); }
  async stop(): Promise<void> {
    try { await this.api.stop(); sessionStorage.removeItem('exl-serve-token'); this.message.set('Serve stopped. You can close this tab.'); }
    catch (error: unknown) { this.message.set(errorText(error)); }
  }
}
