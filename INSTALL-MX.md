# Installazione su MX Linux 25 (PC DJ offline)

Guida per il PC `DDJ1000`: MX Linux 25.3, Debian 13, systemd, kernel 6.12.
Il PC resta offline: Internet serve **solo** durante la fase 1.

---

## Fase 0 — Prima di iniziare

1. **Secure Boot disattivato** nel BIOS (evita la registrazione della chiave MOK).
2. Avvio con la voce **systemd** del menu. Controllo:
   ```
   ps -p 1 -o comm=
   ```
   deve rispondere `systemd`.
3. Copia questa cartella sul PC (chiavetta USB o `git clone`), per esempio in
   `~/ddj1000-linux-driver`.

### Opzionale: lavorare da un altro computer via SSH (VS Code)

Sul PC DJ, collegato alla rete di casa:

```
sudo apt install openssh-server
sudo systemctl enable --now ssh
hostname -I
```

L'ultimo comando mostra l'IP (es. `192.168.1.50`). Dal tuo computer:

- terminale: `ssh DDJ1000@192.168.1.50`
- copia dell'archivio: `scp ddj1000-linux-driver-mx.tar.gz DDJ1000@192.168.1.50:~`
  poi sul PC `tar -xzf ddj1000-linux-driver-mx.tar.gz`
- VS Code: estensione **Remote - SSH** → "Connect to Host…" →
  `DDJ1000@192.168.1.50`; puoi trascinare file nella barra Explorer

I comandi con `sudo` chiedono la password nel terminale di VS Code.
Quando il PC torna offline, SSH può restare installato: senza rete non è
raggiungibile. Se preferisci, disattivalo con `sudo systemctl disable --now ssh`.

## Fase 1 — Con Internet collegato

### 1.1 Allinea kernel e sorgenti

DKMS compila il driver con i sorgenti del pacchetto `linux-source-6.12`, che
deve avere **la stessa versione** del kernel installato. Il modo più semplice
è portare il kernel all'ultima versione disponibile, poi bloccarlo di nuovo:

```
sudo apt-mark unhold linux-image-amd64 linux-headers-amd64
sudo apt update
sudo apt full-upgrade
sudo reboot
```

Dopo il riavvio (sempre voce systemd):

```
uname -r
sudo apt-mark hold linux-image-amd64 linux-headers-amd64 \
  linux-image-$(uname -r) linux-headers-$(uname -r)
```

### 1.2 Installa le dipendenze

```
cd ~/ddj1000-linux-driver
bash scripts/install-ddj1000-audio-driver.sh deps
bash scripts/setup-linux.sh install-host-stack-packages
sudo apt install linux-source-6.12 python3 libusb-1.0-0
```

Controlla che versione dei sorgenti e kernel coincidano:

```
dpkg-query -W -f='${Version}\n' linux-source-6.12 linux-image-$(uname -r)
```

Le due righe devono essere uguali. Se non lo sono, la build di solito
funziona lo stesso (stessa serie 6.12), ma lo script lo segnala con un
`WARNING`.

### 1.3 Installa il driver e i servizi

```
bash scripts/install-ddj1000-linux-stack.sh install
```

Fa tre cose: regole udev, pacchetto DKMS (compila il modulo: sul Celeron
servono alcuni minuti) e servizi di sblocco del controller.

Alla fine puoi **scollegare Internet**.

## Fase 2 — Verifica col controller collegato

Collega il DDJ-1000 (se era già collegato: scollega e ricollega).

```
bash scripts/install-ddj1000-linux-stack.sh status
```

Deve risultare `patched module active`. Poi:

| Comando | Risultato atteso |
|---|---|
| `aplay -l` | una scheda `DDJ1000` |
| `amidi -l` | la porta `DDJ-1000 MIDI 1` |
| jog wheel | sparisce la scritta "NO AUDIO DRIVER" |
| `sudo dmesg \| grep -i ddj` | nessun errore |

### Test dei canali (con casse e cuffie collegate)

```
speaker-test -D hw:DDJ1000,0 -c 6 -r 44100 -F S24_3LE -t wav -l 1
```

Una voce annuncia i 6 canali uno dopo l'altro. Annota dove li senti:

| Canali | Atteso | Dove li senti tu |
|---|---|---|
| 1/2 | Master (casse) | |
| 3/4 | Cue (cuffie, manopola mix su CUE) | |
| 5/6 | sconosciuto | |

Se `speaker-test` termina con `Input/output error`, salva l'output di
`sudo dmesg | tail -50` e mandalo.

## Fase 3 — Preparazione per Stembox (strada A)

Stembox deve aprire da solo `hw:DDJ1000,0`. Due servizi del driver tengono
occupate risorse del controller e vanno gestiti:

1. **Servizio sink PipeWire** (esporta il Master al desktop e tiene aperto
   l'audio): disattivalo
   ```
   systemctl --user disable --now ddj1000-host-stack.service
   ```
2. **WirePlumber**: impedisci a PipeWire di aprire il DDJ-1000.
   Crea `~/.config/wireplumber/wireplumber.conf.d/ddj1000.conf`:
   ```
   monitor.alsa.rules = [
     {
       matches = [ { device.name = "~alsa_card.usb-*DDJ*" } ]
       actions = { update-props = { device.disabled = true } }
     }
   ]
   ```
   poi `systemctl --user restart wireplumber pipewire`.
3. Verifica che nessuno tenga l'audio:
   ```
   fuser -v /dev/snd/pcmC*D0p
   ```
4. Priorità realtime per l'audio:
   ```
   sudo usermod -aG audio $USER
   printf '@audio - rtprio 95\n@audio - memlock unlimited\n' | \
     sudo tee /etc/security/limits.d/audio.conf
   ```
   poi logout e login.

**Attenzione al MIDI:** il servizio di sblocco (`ddj1000-unlock.service`)
tiene aperta in lettura la porta MIDI del controller (`amidi -d`) e manda un
keepalive ogni secondo. Se Stembox apre la porta MIDI in modo esclusivo
potrebbe trovarla occupata. Soluzioni possibili: il programma DJ gestisce da
solo handshake e keepalive, oppure servizio e programma usano entrambi l'ALSA
sequencer, che permette a più client di leggere la stessa porta.

## Disinstallare

```
bash scripts/install-ddj1000-linux-stack.sh uninstall
```

Torna al driver standard del kernel.

## Se aggiorni il kernel in futuro

DKMS ricompila il driver da solo durante l'aggiornamento, a patto che:
- sia installato `linux-source-6.12` della stessa versione del nuovo kernel;
- il nuovo kernel sia ancora della serie **6.12** (per altre serie serve una
  nuova patch in `patches/linux/`).

Se la compilazione fallisce, all'avvio scegli il kernel precedente da
"Advanced options" nel menu di GRUB.
