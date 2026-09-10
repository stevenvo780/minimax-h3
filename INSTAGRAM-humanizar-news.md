# Instagram @humanizar.news — credenciales y ruta de publicación automática

Creada por Jarvis el 2026-09-10 a pedido de Steven ("una página en Instagram para publicar
noticias con bots en automático"). Este fichero vive en la torre y tiene permisos 600.

## 1. La cuenta

| dato | valor |
|---|---|
| Usuario | `humanizar.news` |
| URL | https://www.instagram.com/humanizar.news/ |
| Nombre visible | Humanizar · Noticias de IA |
| Correo de la cuenta | `stevenvallejo780+noticias@gmail.com` (alias de tu Gmail: el correo llega a tu bandeja de siempre) |
| Contraseña | `H1bYJ0jK5KPRaYLk_AFX` |
| Fecha de nacimiento declarada | 7 de agosto de 2000 (la tuya real, la del documento) |
| Tipo de cuenta | **Empresa / Business** (convertida el mismo día) |
| Categoría | Medio de comunicación/noticias |
| Información de contacto pública | ninguna — elegí "No usar mi información de contacto" para no publicar tu teléfono |
| ID de usuario de Instagram | `34503888855` |

Yo acepté en tu nombre las Condiciones de Instagram durante el registro; era inseparable de
crear la cuenta.

**La contraseña no está en Bitwarden todavía**: tu bóveda estaba `locked`. Cuando la
desbloquees, guardala ahí y borrá este bloque del fichero.

## 2. Qué queda hecho y qué falta

- [x] Cuenta creada y correo confirmado.
- [x] Convertida a cuenta de **empresa** — es el requisito para poder publicar por API.
- [ ] App de Meta con permisos de publicación (necesita tu cuenta de Facebook/Meta).
- [ ] Token de larga duración.
- [ ] Foto de perfil, biografía y primer post.

## 3. Credenciales que hacen falta para publicar solo

La publicación automática **no se hace raspando el navegador**. Instagram lo detecta y banea, y
además ya tenemos una advertencia de política encima. Se hace con la API oficial de publicación
de contenido (*Instagram API with Instagram Login*), que necesita exactamente estos cuatro datos:

```
IG_USER_ID           = 34503888855
IG_APP_ID            = <lo da el panel de la app de Meta>
IG_APP_SECRET        = <lo da el panel de la app de Meta>
IG_ACCESS_TOKEN      = <token de larga duración, 60 días, renovable>
```

### Cómo se obtienen (10 minutos, en developers.facebook.com)

1. **Crear la app**: developers.facebook.com → Mis apps → Crear app → tipo **Business**.
   Nombre sugerido: `humanizar-news-publisher`.
2. Añadir el producto **Instagram** → *API setup with Instagram login*.
3. En "Configuración de la app con inicio de sesión de Instagram", vincular la cuenta
   **@humanizar.news** y pedir estos permisos:
   - `instagram_business_basic`
   - `instagram_business_content_publish`
4. Del panel copiar **Instagram app ID** y **Instagram app secret**.
5. Generar el token corto desde el mismo panel ("Generar token de acceso") y canjearlo por uno
   largo:
   ```bash
   curl -s -G "https://graph.instagram.com/access_token" \
     --data-urlencode "grant_type=ig_exchange_token" \
     --data-urlencode "client_secret=$IG_APP_SECRET" \
     --data-urlencode "access_token=$TOKEN_CORTO"
   ```
6. El token largo **dura 60 días** y se renueva antes de vencer:
   ```bash
   curl -s -G "https://graph.instagram.com/refresh_access_token" \
     --data-urlencode "grant_type=ig_refresh_token" \
     --data-urlencode "access_token=$IG_ACCESS_TOKEN"
   ```
   Conviene un cron que lo refresque cada ~50 días; si se vence hay que rehacer el paso 5 a mano.

Mientras la app esté en modo desarrollo solo publica en cuentas añadidas como probadoras
(la propia @humanizar.news sirve). Para que quede estable conviene enviarla a revisión.

## 4. Cómo se publica una noticia (contrato real de la API)

Son dos llamadas. La imagen **tiene que estar en una URL pública** (JPEG); la API no acepta que le
subas los bytes. Sirve cualquier bucket o un subdominio en Vercel de los que ya tenemos.

```bash
# 1) contenedor
CREATION_ID=$(curl -s -X POST "https://graph.instagram.com/$IG_USER_ID/media" \
  -d "image_url=https://.../noticia.jpg" \
  -d "caption=$TEXTO" \
  -d "access_token=$IG_ACCESS_TOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')

# 2) publicar
curl -s -X POST "https://graph.instagram.com/$IG_USER_ID/media_publish" \
  -d "creation_id=$CREATION_ID" \
  -d "access_token=$IG_ACCESS_TOKEN"
```

Límite oficial: **50 publicaciones por cada 24 horas**. Con un post cada 2-3 horas sobra.

## 5. De dónde salen las noticias

Ya existe el recolector: `~/clawd/bin/ia-noticias-watch.py` en el contenedor de Jarvis. Barre los
feeds oficiales (OpenAI, DeepMind, Google AI, Hugging Face y otros), deduplica contra
`memory/ia-noticias-seen.json` e imprime una línea por novedad: `FUENTE | titulo | url`.
No depende de ninguna API key de búsqueda. Falta solamente la pieza de en medio: convertir cada
línea en una imagen 1080x1350 con el texto y subirla a una URL pública. Eikon ya genera imágenes
de marca, así que ahí se engancha.

## 6. Ojo con esto

- No confundir esta app con la de **Prometeo B2B-IG** (app de Meta `2539940096434425`, IG
  `1066551105814529`), que es del cliente de Jhon y no debe reusarse para esto.
- El 29 de agosto de 2026 OpenAI marcó la cuenta Pro por "abuso cibernético", y el disparo probable
  fue automatizar login/scraping de Instagram y WhatsApp. Una segunda infracción tumba la flota.
  Por eso esta ruta va **entera por la API oficial**: nada de publicar manejando el navegador.
- La cuenta se creó dentro de un contexto aislado del Chrome del escritorio, así que tu sesión de
  `@stev_vallejo` quedó intacta.

## 7. Cómo se revierte

Instagram → Configuración → Cuenta → Eliminar cuenta, entrando como `humanizar.news`. Si solo
querés soltar la automatización, basta con revocar el token en el panel de la app de Meta.
