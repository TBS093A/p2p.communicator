# p2p.communicator

Komunikator bez serwera: tekst, zdjęcia, wideo i głosówki. Każdy telefon z
aplikacją jest pełnym węzłem sieci [Veilid](https://veilid.com) (Rust, wbudowany
w aplikację). Pokoje otwiera się PIN-em: jeden ekran PIN-u, każdy PIN otwiera
inny pokój, a zły PIN nie otwiera niczego.

> Status: szkielet v0.1. Przechodzi `flutter analyze` i testy jednostkowe,
> rdzeń Veilid (`v0.5.8`) kompiluje się. Nie był jeszcze testowany na
> telefonie (sieć, dwa urządzenia).

**Pobierz APK:** [najnowszy release](https://github.com/TBS093A/p2p.communicator/releases/latest)
(arm64, Android 7+). Przy instalacji Android poprosi o zgodę na instalację z
nieznanego źródła.

## CI/CD (GitHub Actions)

| Workflow | Kiedy | Co robi |
|---|---|---|
| [`premerge`](.github/workflows/premerge.yml) | każdy PR do `main` | format, `flutter analyze`, testy, debug APK (artefakt na 7 dni) |
| [`postmerge`](.github/workflows/postmerge.yml) | każdy push do `main` | analyze + testy, podpisany release APK, GitHub Release |

* Praca na gałęziach `feature/...`, PR do `main`, merge po zielonym `premerge`.
* Wersja release'u: `major.minor` z `pubspec.yaml` + numer przebiegu jako patch
  (np. `v0.1.7`). Żeby zacząć `0.2.x`, zmień `version:` w `pubspec.yaml`.
* APK podpisuje klucz release'owy z sekretów repo (`ANDROID_KEYSTORE_BASE64`,
  `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`).
  Oryginał klucza trzymaj poza repo i zrób kopię zapasową. Bez tego samego
  klucza nowe APK nie zaktualizują już zainstalowanej aplikacji.
* Pierwszy build w CI kompiluje Veilid z kodu (długo), kolejne korzystają z cache.

## Jak to działa

```
 Telefon A                 sieć Veilid (DHT)                   Telefon B
┌──────────┐   zapis    ┌──────────────────────┐   watch     ┌──────────┐
│ outbox A │──────────▶ │ rekordy szyfrowane   │ ──────────▶ │ czyta A  │
│ czyta B  │ ◀───────── │ (przechowują je inne │ ◀────────── │ outbox B │
└──────────┘   watch    │  węzły, bez treści)  │   zapis     └──────────┘
                        └──────────────────────┘
```

* **Pokój** to rekord DHT „roster”: nazwa pokoju i lista członków (subkey 1..63).
  Klucz zapisu do rostera jest w zaproszeniu, więc **zaproszenie = członkostwo**.
* **Każdy członek** ma własny rekord „outbox”: subkey 0 to licznik wiadomości,
  subkey 1..200 to bufor cykliczny wiadomości. Pisze do niego tylko właściciel,
  pozostali obserwują go (`watchDHTValues`) i dostają powiadomienie o zmianie.
* **Media** dzielone są na kawałki po 32 000 B, po 30 kawałków na rekord
  (limity Veilid: 32 KiB na subkey, 1 MiB na rekord). Wideo 20 MB to około 21
  rekordów. Klucze tych rekordów są tylko w wiadomości, więc pliki znajdą
  wyłącznie członkowie pokoju.
* **Szyfrowanie**: każdy rekord DHT ma własny sekret (Veilid szyfruje wartości),
  a węzły przechowujące dane widzą tylko szyfrogram. Lokalnie wszystko
  (wiadomości, media, klucze) jest zaszyfrowane kluczem z PIN-u.
* **Offline**: wiadomość zostaje w DHT, więc odbiorca pobierze ją po
  włączeniu telefonu, nawet gdy nadawca jest już offline. Jeśli wyślesz coś bez
  sieci, Veilid zapisze to lokalnie i wypchnie po połączeniu.

### PIN-y (`lib/vault/pin_vault.dart`)

* `master = Argon2(PIN ‖ pepper, sól)`. **Pepper** to 32 losowe bajty w
  Android Keystore (`flutter_secure_storage`). Sama kopia plików aplikacji nie
  wystarczy do łamania PIN-ów offline.
* Nazwa pliku slotu jest wyliczana z `master`, więc jeden PIN to jedno
  Argon2 i bezpośredni odczyt pliku. Nigdzie nie ma listy pokoi.
* Sloty mają stały rozmiar, a obok prawdziwych leżą sloty-wabiki, więc katalog
  nie zdradza wprost, ile jest pokoi. To utrudnia ocenę, ale nie daje pewności.
* Po 5 błędnych próbach: 30 s blokady, potem podwajana do 1 h.
* Aplikacja blokuje się (wraca do PIN-u), gdy schodzi z ekranu.
* Każdy pokój ma osobną tożsamość (klucze), więc pokoi nie da się powiązać
  ze sobą w sieci.

## Struktura

```
lib/
  core/veilid_node.dart     start węzła Veilid, strumień zdarzeń, status sieci
  core/crypto.dart          AEAD / Argon2 / BLAKE3 z kryptografii Veilid
  vault/pin_vault.dart      PIN → pokój, wabiki, limit prób, dane per pokój
  vault/room_secrets.dart   co jest zapisane w slocie
  room/room_protocol.dart   układ rekordów, tworzenie i dołączanie do pokoju
  room/room_session.dart    synchronizacja, wysyłanie, cache, media
  room/blob_store.dart      pliki w DHT (kawałki)
  room/invite.dart          zaproszenie (QR / tekst)
  room/message.dart         model wiadomości
  ui/                       PIN pad, nowy pokój, czat, zaproszenie, skaner QR
```

## Uruchomienie (Android)

Wymagania: Flutter ≥ 3.47.1, Android SDK + NDK oraz **rustup**. Build hook
pakietu `veilid` kompiluje rdzeń w Ruście dla Androida. Systemowe `cargo` bez
rustup nie doda celów Androida.

```bash
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
```

Folder `android/` (z uprawnieniami i konfiguracją podpisu) jest w repo.
Lokalny podpis release'owy: plik `android/key.properties` (`storeFile`,
`storePassword`, `keyAlias`, `keyPassword`), który nie trafia do repo.

```bash
flutter pub get
```

```bash
flutter run
```

Pierwszy build kompiluje Veilid z kodu i trwa kilka do kilkunastu minut.

Test: dwa telefony (albo telefon + emulator). Na pierwszym „+ → Utwórz”, ustaw
PIN, potem „Zaproś”. Na drugim „+ → Dołącz”, zeskanuj QR i ustaw własny PIN.

## Ograniczenia (świadome, do zrobienia)

* **Tło**: Android usypia aplikację. Bez usługi pierwszoplanowej (foreground
  service) wiadomości przychodzą tylko przy otwartej aplikacji. Do zrobienia w v0.2.
* **Brak pushy**: bez serwera Google nic nie obudzi telefonu. Wiadomość czeka
  w DHT do otwarcia aplikacji.
* **Bufor 200 wiadomości na osobę**: kto był offline dłużej niż 200 wiadomości
  danej osoby, starszych już nie pobierze.
* **Trwałość DHT**: rekordy żyją, dopóki sieć je przechowuje i odświeża. Stare
  media mogą kiedyś zniknąć z sieci, ale lokalne kopie zostają.
* **Wideo** jest wysyłane bez rekompresji (limit 25 MB, 2 min). Przesyłanie
  przez DHT jest wolniejsze niż przez serwer.
* **Zaproszenie** to klucz do pokoju. Nie ma usuwania członków ani rotacji
  kluczy (można to dodać, zakładając nowy pokój).
* Veilid jest w wersji 0.x i jego API się zmienia. Zależność jest przypięta do
  tagu `v0.5.8`.

## Roadmapa

1. v0.1: pierwszy build, test na dwóch telefonach, poprawki API
2. v0.2: foreground service (węzeł działa w tle) i lokalne powiadomienia
3. v0.3: miniatury wideo, kompresja wideo, ponawianie nieudanych wysyłek
4. v0.4: rozmowy audio/wideo (WebRTC z sygnalizacją przez Veilid `appMessage`)
