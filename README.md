# BM Mobils — tienda online

Tienda de telefonía móvil (nuevos, reacondicionados y de segunda mano, tablets y accesorios) para el mercado español, con panel de administración, pagos con Stripe y base de datos PostgreSQL.

## Arquitectura

| Pieza | Elección | Motivo |
|---|---|---|
| Web | Next.js 16 (App Router) + React 19 + TypeScript | Renderizado en servidor (SEO y velocidad) y server actions para todas las operaciones |
| Estilos | Tailwind CSS 4, Inter, iconos Lucide | Diseño consistente sin librerías de componentes pesadas |
| Datos | PostgreSQL + Prisma 7 (adaptador `pg`) | Esquema relacional con migraciones, índices y restricciones `CHECK` |
| Autenticación | Propia: sesiones en base de datos, cookies `httpOnly`, bcrypt y roles | Un único sistema para clientes y equipo, sin depender de servicios externos |
| Pagos | Stripe Checkout + webhook firmado | La tarjeta la introduce el cliente en la página de Stripe y nunca pasa por nuestro servidor |
| Imágenes | Disco local en desarrollo, Supabase Storage en producción | Se cambia con `STORAGE_DRIVER` |
| Correo | Resend (opcional) | Sin clave, los correos se escriben en la consola |
| Validación | Zod (cliente y servidor) + React Hook Form | El servidor valida siempre, aunque el cliente ya lo haya hecho |

Supabase se puede usar como proveedor de PostgreSQL y de almacenamiento. Su sistema de autenticación no se usa para no mezclar dos soluciones.

```
prisma/            esquema, migraciones y datos iniciales (seed)
scripts/           base de datos local y alta de administradores
src/app/(store)/   tienda pública
src/app/admin/     panel (/admin) y sus server actions
src/app/api/       webhook de Stripe, cron, búsqueda
src/lib/           lógica de negocio: catálogo, carrito, precios, pedidos, auth, permisos…
src/components/    componentes de la tienda, del panel y de interfaz
tests/             pruebas unitarias y de integración (Vitest)
```

### Precios, impuestos y stock

- **Precios:** se guardan en céntimos (`Int`), con el IVA incluido (venta a consumidores en España). Cada producto tiene su tipo de IVA (2100 = 21 %) y se copia en cada línea de pedido. El IVA de los gastos de envío usa el tipo general de la configuración.
- **Canarias, Ceuta y Melilla:** no aplica el IVA (allí rigen IGIC e IPSI). Los pedidos a estas zonas se marcan como "requiere revisión fiscal". **Define el tratamiento con tu asesor.**
- **Cálculo en servidor:** el servidor recalcula siempre precios, descuentos y envío a partir de la base de datos. Nunca se usa un importe enviado por el navegador.
- **Reserva de stock:** al iniciar el pago, el stock se reserva con un `UPDATE … WHERE stock >= cantidad` dentro de una transacción. Además, la base de datos impide el stock negativo con una restricción `CHECK`. Hay una prueba con 20 compras simultáneas contra 5 unidades: se venden exactamente 5.
- **Liberación del stock:** si el pago no se completa en 31 minutos, la reserva se libera. Se hace por tres vías: el webhook `checkout.session.expired`, la tarea programada `/api/cron/release-reservations`, y la vuelta del cliente desde Stripe sin pagar.

### Flujo de pago

1. **Creación del pedido:** en el checkout se valida la dirección, se reserva el stock y se crea el pedido con estado "Pendiente de pago".
2. **Pago en Stripe:** el cliente paga en Stripe Checkout, con los métodos que actives en tu panel de Stripe.
3. **Confirmación:** el pedido solo pasa a "Pagado" cuando llega el webhook firmado (`checkout.session.completed` o `async_payment_succeeded`) y el importe cobrado coincide con el total. Si no coincide, el pedido queda en "Requiere revisión".
4. **Pagos fallidos o caducados:** se cancela el pedido y se libera el stock.
5. **Reembolsos:** se piden desde el panel (solo un administrador). El estado cambia a "Reembolsado" cuando Stripe lo confirma (`charge.refunded`).
6. **Idempotencia:** cada evento de Stripe se procesa una sola vez, aunque llegue repetido.

### Estados de pedido

`Pendiente de pago → Pagado → Preparando → Enviado → Entregado`, más `Cancelado` y `Reembolsado`.

- **Pagado y Reembolsado:** solo los fija Stripe.
- **Enviado:** exige registrar el transportista y el número de seguimiento.
- **Entregado:** se marca a mano tras la confirmación del transportista.
- **Cancelar un pedido cobrado:** no se puede; hay que reembolsarlo.

### Roles

| Permiso | Administrador | Equipo | Cliente |
|---|---|---|---|
| Panel, pedidos, productos | ✓ | ✓ | – |
| Reembolsos, borrar productos, configuración, cupones, páginas legales, roles | ✓ | – | – |
| Ver clientes | ✓ | ✓ (solo los datos necesarios) | – |

Los permisos están en `src/lib/permissions.ts` y se comprueban en el servidor en cada página y en cada acción.

## Puesta en marcha en local

Necesitas Node.js 20.19 o superior (probado con 22.23).

```bash
npm install
```

Crea tu `.env` a partir de `.env.example`. `SESSION_SECRET` necesita una cadena aleatoria de al menos 32 caracteres; puedes generarla así:

```bash
node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
```

Arranca PostgreSQL local en una terminal aparte y déjala abierta. No necesita instalación: los datos se guardan en `.local-db/`.

```bash
npm run db:local
```

En otra terminal, aplica las migraciones:

```bash
npm run db:migrate
```

Carga los datos iniciales: configuración, categorías, tarifas de ejemplo, páginas legales y productos de demostración.

```bash
npm run db:seed
```

Crea tu usuario administrador. Si no defines `ADMIN_PASSWORD`, se genera una contraseña y se muestra una sola vez.

```bash
npm run admin:create -- tu@email.es "Tu nombre"
```

Arranca la tienda:

```bash
npm run dev
```

- Tienda: http://localhost:3000
- Panel: http://localhost:3000/admin

### Comprobaciones

```bash
npm run typecheck
```

```bash
npm run lint
```

```bash
npm test
```

La prueba de stock usa la base de datos local; si no está disponible, se omite.

### Probar pagos en modo de prueba

1. Crea una cuenta en https://dashboard.stripe.com y activa el **modo de prueba**.
2. En *Developers → API keys*, copia la clave secreta `sk_test_…` en `STRIPE_SECRET_KEY`.
3. Instala la [CLI de Stripe](https://docs.stripe.com/stripe-cli) y reenvía los webhooks a tu equipo:

   ```bash
   stripe listen --forward-to localhost:3000/api/stripe/webhook
   ```

   Copia el secreto `whsec_…` que muestra en `STRIPE_WEBHOOK_SECRET` y reinicia `npm run dev`.
4. Paga con la tarjeta de prueba `4242 4242 4242 4242`, cualquier fecha futura y cualquier CVC. Más tarjetas de prueba (rechazos, 3D Secure…) en https://docs.stripe.com/testing.

Sin estas dos variables, el checkout muestra que los pagos no están activados y no deja pagar: **no se simulan pagos**.

## Despliegue en producción

Recomendado: **Vercel** para la web y **Supabase** para PostgreSQL y almacenamiento. Cualquier servidor con Node.js y PostgreSQL vale.

1. **Base de datos:** crea un proyecto en Supabase. En *Project Settings → Database*, copia la cadena de conexión en `DATABASE_URL`.
2. **Almacenamiento:** en *Storage*, crea un bucket **público** llamado `product-images`. Configura `STORAGE_DRIVER=supabase`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` y `SUPABASE_STORAGE_BUCKET`. La clave de servicio solo se usa en el servidor.
3. **Vercel:** importa el repositorio y añade todas las variables de `.env.example`, con `NEXT_PUBLIC_SITE_URL=https://tudominio.es`.
4. **Migraciones:** aplícalas contra la base de datos de producción (una vez y en cada cambio de esquema):

   ```bash
   npm run db:deploy
   ```

   Ejecuta también `npm run db:seed` una vez (no sobrescribe datos existentes) y `npm run admin:create` con tu email.
5. **Webhook de Stripe:** en *Developers → Webhooks*, añade el endpoint `https://tudominio.es/api/stripe/webhook` con estos eventos:
   - `checkout.session.completed`
   - `checkout.session.async_payment_succeeded`
   - `checkout.session.async_payment_failed`
   - `checkout.session.expired`
   - `charge.refunded`

   Copia su secreto en `STRIPE_WEBHOOK_SECRET`.
6. **Pagos reales:** cuando todo funcione en modo de prueba, cambia a las claves `sk_live_…` y crea el webhook equivalente en modo real.
7. **Tarea programada:** programa cada 10–15 minutos una llamada a `GET /api/cron/release-reservations` con la cabecera `Authorization: Bearer <CRON_SECRET>`. Puede hacerse con Vercel Cron o Supabase Cron.
8. **Correo:** crea una cuenta en Resend, verifica tu dominio y configura `RESEND_API_KEY` y `EMAIL_FROM`.

> `STORAGE_DRIVER=local` no sirve en Vercel: el disco no es persistente, y Next.js solo sirve los archivos de `public/` que existían al compilar.

## Credenciales y servicios que debes configurar

| Variable | Dónde se obtiene | Obligatoria |
|---|---|---|
| `DATABASE_URL` | Supabase u otro PostgreSQL | Sí |
| `SESSION_SECRET` | Generarla (cadena aleatoria) | Sí |
| `NEXT_PUBLIC_SITE_URL` | Tu dominio | Sí |
| `STRIPE_SECRET_KEY` | Panel de Stripe → API keys | Para cobrar |
| `STRIPE_WEBHOOK_SECRET` | Stripe → Webhooks (o `stripe listen`) | Para cobrar |
| `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_STORAGE_BUCKET` | Supabase → Settings → API / Storage | Para subir fotos en producción |
| `RESEND_API_KEY`, `EMAIL_FROM` | Resend | Para enviar correos |
| `CRON_SECRET` | Generarla | Para liberar reservas por cron |

Además, decisiones del negocio que debes revisar en el panel:

- **Tarifas de envío:** las del seed son de ejemplo. Revísalas en Configuración → Tarifas de envío.
- **Textos legales:** completa los `[PENDIENTE]` de Páginas y haz que los revise un asesor.
- **Datos fiscales:** razón social, NIF y domicilio, en Configuración.
- **Fiscalidad de Canarias, Ceuta y Melilla:** define el tratamiento con tu asesor.
- **Productos de demostración:** quita la marca "Demostración" solo a los que existan de verdad, o archívalos.

## Funcionalidades

### Terminadas

**Comprobado en el navegador con la base de datos local:**

- **Catálogo:** filtros, ordenación y búsqueda.
- **Ficha de producto:** cambio de variante con su precio.
- **Carrito:** añadir, cambiar cantidades y aplicar cupones (también el rechazo de un cupón inexistente).
- **Checkout:** totales, provincia y zona según el código postal, aviso fiscal de Canarias y bloqueo del pago sin Stripe.
- **Panel:**
  - Login.
  - Resumen calculado con un pedido real.
  - Edición de producto con ajuste de stock e historial.
  - Cupones.
  - Ciclo de un pedido pagado: Preparando → Enviado → Entregado, con historial y correos.
  - Configuración, tarifas y páginas legales.
- **Contacto:** formulario con validación, y el mensaje llega al panel.
- **Seguridad:** 404 reales, protección de `/admin`, cron y webhook, y pedidos invisibles sin el enlace firmado.

**Implementado pero no recorrido en el navegador:**

- Registro de clientes.
- Subida y orden de fotos.
- Banners.
- Plantillas de correo.
- Cambio de roles.
- Límites de peticiones.

En detalle:

- **Tienda:**
  - Portada configurable desde el panel: titular, barra informativa, imagen y banners.
  - Categorías y URLs limpias: `/moviles`, `/iphone`, `/samsung`, `/accesorios`, `/ofertas`… También admite cualquier categoría o marca nueva.
- **Catálogo:**
  - Filtros reales sobre la base de datos: marca, modelo, almacenamiento, color, estado, categoría, salud de batería, disponibilidad y precio.
  - Cinco ordenaciones, paginación, chips de filtros con botón para quitarlos, contador de resultados, estado de carga y estado vacío.
- **Búsqueda:** por nombre, marca, modelo y SKU, con sugerencias mientras escribes y navegación con teclado.
- **Ficha de producto:**
  - Galería, selector de estado estético, capacidad y color con precio y stock reales, cantidad, "Añadir al carrito" y "Comprar ahora".
  - Salud de batería solo si está comprobada.
  - Especificaciones, estado del dispositivo, garantía, devoluciones, envío, accesorios compatibles y productos relacionados.
- **Carrito:** guardado en servidor (se conserva 60 días), cantidades, cupones validados en servidor y avisos por línea si cambia el stock.
- **Checkout:**
  - Contacto, dirección, provincia rellenada a partir del código postal y país.
  - Facturación opcional con validación de NIF, NIE o CIF.
  - Envío según la zona, total con IVA desglosado y aceptación de condiciones.
- **Pedidos:** página de confirmación con enlace firmado (solo la ve su titular) y cuenta de cliente con historial.
- **Panel:**
  - **Resumen:** ventas del día y del mes, pedidos, pendientes, productos publicados, poco stock y gráfico de 30 días, todo calculado a partir de pedidos reales.
  - **Productos:** crear, editar, publicar, despublicar, archivar y eliminar; fotos, variantes, precios promocionales, stock con historial de movimientos, especificaciones, estado del dispositivo, batería, destacados y SEO.
  - **Pedidos:** filtros, cambios de estado con reglas, registro de envíos, reembolsos y notas internas.
  - **Resto:** clientes con y sin cuenta (roles y desactivación), cupones, mensajes de contacto, páginas legales editables con vista previa y configuración completa, incluidas las plantillas de correo.
- **SEO:**
  - Metadatos y canonical por página, Open Graph, `sitemap.xml` y `robots.txt`.
  - JSON-LD de Product y BreadcrumbList.
  - Páginas filtradas y productos de demostración con `noindex`, y 404 reales.
  - Imágenes optimizadas con `next/image`.
- **Seguridad:**
  - Validación en servidor, control de acceso por roles y contraseñas con bcrypt.
  - Sesiones guardadas como hash, límite de peticiones en el login, el registro, los cupones, el checkout y el formulario de contacto.
  - Webhook con firma verificada, cabeceras de seguridad y subida de imágenes validada por su contenido.
- **Experiencia de usuario:** avisos de éxito y error, confirmación antes de acciones destructivas, esqueletos de carga, página 404, estados vacíos y aviso de cookies (solo cookies técnicas; las opcionales quedan bloqueadas hasta que se acepten).
- **Comprobaciones:** TypeScript, lint y 24 pruebas sin errores; la compilación de producción termina bien; la tienda y el panel funcionan a 375 px de ancho sin desbordamiento.

### Preparado pero sin probar de punta a punta (faltan credenciales)

- **Cobro real con Stripe:** creación de la sesión, webhooks y reembolsos. La verificación de la firma sí está probada.
- **Correos con Resend:** sin clave se escriben en la consola.
- **Subida de imágenes a Supabase Storage:** en local se prueban con disco.

### Pendiente / posibles mejoras

- Recuperar contraseña por correo (necesita el correo configurado).
- Libreta de direcciones de cliente y facturas en PDF.
- Formulario para que los clientes dejen reseñas tras una compra verificada. El esquema y la moderación ya existen y no se muestran valoraciones inventadas.
- Gestión de marcas y categorías desde el panel. Por ahora se crean en el seed o con `npm run db:studio`.
- Analítica: si se añade, cargarla solo con consentimiento (`hasConsent('analytics')`).
