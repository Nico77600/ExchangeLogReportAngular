import { bootstrapApplication } from '@angular/platform-browser';
import { provideHttpClient } from '@angular/common/http';
import { provideZonelessChangeDetection } from '@angular/core';
import { provideRouter } from '@angular/router';
import { AppComponent } from './portal';
import { routes } from './routes';

bootstrapApplication(AppComponent, {
  providers: [provideHttpClient(), provideZonelessChangeDetection(), provideRouter(routes)]
}).catch((error: unknown) => {
  console.error(error);
  document.body.textContent = 'The portal could not start. See the browser console and host window.';
});
