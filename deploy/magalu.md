# Deploy do M-Engine 24h na Magalu Cloud (VM + Docker Compose)

Runbook para subir o M-Engine numa **Máquina Virtual** da Magalu Cloud, com dados num
**Block Storage** cifrado, acesso **privado via Tailscale** e **backup** num **bucket Object Storage**.

> **Conceitos.** A *VM* roda os containers (compute, descartável). O *Block Storage* é um SSD
> anexado à VM e montado como pasta (`/var/lib/m-data`) — guarda o estado clínico vivo (PHI). O
> *Object Storage (bucket S3)* guarda backups/áudios frios. Se a VM morrer, recria-se sem perder dado:
> o estado mora no volume, não na VM.

```
Mac / iPhone (app SwiftUI) ──Tailnet 100.x──▶ VM Magalu
                                              ├─ docker compose: api :8000 · worker · redis
                                              └─ /var/lib/m-data  (Block, LUKS)
                                                 ├─ pat/    (dossiês PHI)
                                                 └─ audio/  (uploads + transcrições)
                                                      └─rclone sync─▶ bucket m-backups (Object Storage)
```

Todos os comandos abaixo rodam **na VM** (via SSH / DesktopCommander), como root ou com `sudo`,
salvo onde indicado.

---

## 1. Provisionar recursos (`mgc` CLI ou painel)

1. **VM**: a que você já tem. Recomendado **≥ 4 vCPU / 8 GB RAM**.
2. **Block Storage** (volume cifrado, mesma AZ da VM) — via `mgc` no seu Mac/estação:
   ```bash
   VM=$(mgc virtual-machine instances list -o json | jq -r '.instances[0].id')   # ou copie o id
   mgc block-storage volumes create --name m-data --size 100 \
       --type.name cloud_nvme5k --availability-zone br-se1-a --encrypted
   VOL=$(mgc block-storage volumes list -o json | jq -r '.volumes[] | select(.name=="m-data").id')
   mgc block-storage volumes attach --id "$VOL" --virtual-machine-id "$VM"
   ```
   O volume aparece na VM como novo disco (ex.: `/dev/vdb`, confirme com `lsblk`).
3. **Object Storage**: o bucket é criado no §6 com o próprio `mgc` (nativo Magalu, **não é AWS** —
   só fala o protocolo S3). Autenticação por **API key** do ID Magalu.

---

## 2. Preparar a VM (SO + Docker)

```bash
sudo apt update && sudo apt -y upgrade
# Docker Engine + plugin compose (script oficial)
curl -fsSL https://get.docker.com | sudo sh
sudo apt -y install git
sudo systemctl enable --now docker
```

> O **Block Storage** já é criado **cifrado em repouso** pelo provider (flag `--encrypted` no §1),
> então não precisamos de LUKS — menos fragilidade no boot (sem keyfile/crypttab). Quem quiser uma
> 2ª camada pode aplicar LUKS por cima; aqui usamos a cripto gerenciada da Magalu.

---

## 3. Formatar e montar o Block (cifrado pelo provider)

```bash
lsblk                                    # o volume anexado aparece como novo disco (ex.: /dev/vdb)
DEV=/dev/vdb
sudo blkid "$DEV" || echo "vazio — ok p/ formatar"   # confirme que está VAZIO (não é o /dev/vda do SO!)

sudo mkfs.ext4 -q -L m-data "$DEV"
sudo mkdir -p /var/lib/m-data
sudo mount "$DEV" /var/lib/m-data
sudo chmod 770 /var/lib/m-data           # o container ajusta dono nos subdirs que cria

# Remontar no boot via fstab (por UUID; nofail evita travar o boot se faltar)
UUID=$(sudo blkid -s UUID -o value "$DEV")
echo "UUID=$UUID  /var/lib/m-data  ext4  defaults,nofail  0  2" | sudo tee -a /etc/fstab
sudo umount /var/lib/m-data && sudo mount -a && mountpoint /var/lib/m-data   # testa o fstab
```

---

## 4. Rede privada (Tailscale)

```bash
curl -fsSL https://tailscale.com/install.sh | sudo sh
sudo tailscale up                         # autentique a VM na sua tailnet
tailscale ip -4                           # anote o IP 100.x.y.z da VM
```

- Instale o Tailscale também no **Mac** e no **iPhone** (mesma conta/tailnet).
- **Firewall / Security Group da Magalu**: **não abra a porta 8000** para a internet. Deixe inbound
  público só o necessário (idealmente nem SSH — use **Tailscale SSH**). O Tailscale não precisa de
  porta inbound aberta.

---

## 5. Subir o m-engine (Docker Compose)

```bash
sudo git clone https://github.com/myselfgus/m.git /opt/m-engine
cd /opt/m-engine

# .env (NÃO vai ao git) — modo 0600
sudo cp .env.example .env
sudo nano .env        # preencha:
#   ANTHROPIC_API_KEY=...
#   ELEVENLABS_API_KEY=...
#   M_BASE=/var/lib/m-data
#   M_API_BIND=100.x.y.z        ← IP Tailscale da VM (publica a API só na tailnet)
#   REDIS_URL fica interno (o compose já injeta redis://redis:6379/0)
sudo chmod 600 .env

# o compose interpola ${M_BASE} e ${M_API_BIND} do ambiente — exporte para o 'up'
export M_BASE=/var/lib/m-data
export M_API_BIND=100.x.y.z

# valide a config antes de subir (confira o mapeamento de volume e a porta)
sudo -E docker compose -f deploy/docker-compose.yml config

# suba
sudo -E docker compose -f deploy/docker-compose.yml up -d --build
```

> **Auth de provider:** apenas **API keys** (VM headless). O alias `cc` (Claude Code CLI) fica de
> fora — exigiria `claude` logado na VM.

---

## 6. Backup para o bucket (Object Storage nativo Magalu, via `mgc`)

> O Object Storage é **produto nativo da Magalu** (br-se1). Usamos o **`mgc` CLI** —
> sem AWS, sem rclone. O bucket e os dados ficam na Magalu.

Instale e autentique o `mgc` **na VM** (headless, por API key):

```bash
curl -fsSL https://raw.githubusercontent.com/MagaluCloud/mgccli/main/scripts/install.sh | sudo bash
# Autenticação headless: gere uma API key no painel (ID Magalu → API keys) e configure:
mgc auth api-key set            # cole a API key quando pedir  (ou: mgc workspace ...)
mgc object-storage buckets list # deve responder sem erro
```

Crie o bucket (privado, versionado) — pode ser feito da VM ou do seu Mac:

```bash
mgc object-storage buckets create --bucket m-engine-backups --private --enable-versioning
```

Teste e agende o `deploy/backup.sh` (usa `mgc object-storage objects sync`):

```bash
sudo M_BASE=/var/lib/m-data BUCKET=m-engine-backups /opt/m-engine/deploy/backup.sh

# cron (root): backup noturno 03:30
echo '30 3 * * * root M_BASE=/var/lib/m-data BUCKET=m-engine-backups /opt/m-engine/deploy/backup.sh >> /var/log/m-backup.log 2>&1' | sudo tee /etc/cron.d/m-backup
```

Confira os objetos: `mgc object-storage objects list --bucket m-engine-backups/pat`.

Além disso, agende **snapshots do volume Block** no painel/`mgc` (ex.: 7 diários / 4 semanais) —
defesa extra contra corrupção/ransomware. O volume já é **cifrado em repouso** (criado com `--encrypted`).

---

## 7. App SwiftUI

- Em **Ajustes**, aponte a URL para `http://100.x.y.z:8000` (IP Tailscale da VM, ou o nome MagicDNS) e
  use "Testar conexão".
- O `Info.plist` já tem `NSAllowsLocalNetworking`. Se o iOS tratar o IP 100.x como remoto e bloquear,
  adicione uma exceção `NSExceptionDomains` para o host tailnet (ou use o nome MagicDNS).

---

## 8. Verificação (end-to-end)

```bash
# 1) containers de pé e saudáveis; worker logou o prewarm do cache
sudo docker compose -f /opt/m-engine/deploy/docker-compose.yml ps
sudo docker compose -f /opt/m-engine/deploy/docker-compose.yml logs worker | grep -i prewarm

# 2) healthz local
curl -fsS http://127.0.0.1:8000/healthz        # {"status":"ok","m_base":"/var/lib/m-engine"}

# 3) do Mac, pela tailnet (deve responder); da internet pública (deve falhar)
curl -fsS http://100.x.y.z:8000/healthz
```

4. **Pipeline real**: `POST /audio` com um áudio de teste → `POST /jobs/pipeline` → `GET /jobs/{id}`
   até concluir; confira artefatos em `/var/lib/m-data/pat/<PID>/` (BIRP + SOAP + JSONs).
5. **Backup**: rode `backup.sh` e `mgc object-storage objects list --bucket m-engine-backups/pat`.
6. **Resiliência**: `sudo reboot` → o volume remonta via `fstab` (cifrado pelo provider), os containers
   sobem sozinhos (`restart: always`), os dados persistem e `/healthz` volta sem intervenção.

---

## Operação do dia a dia

```bash
cd /opt/m-engine
sudo -E docker compose -f deploy/docker-compose.yml logs -f api worker   # logs
sudo git pull && sudo -E docker compose -f deploy/docker-compose.yml up -d --build   # atualizar
sudo -E docker compose -f deploy/docker-compose.yml down                 # parar (dados ficam no volume)
```

## Segurança (PHI) — checklist

- [ ] API **não** exposta publicamente (Tailscale + security group fechado; `M_API_BIND` = IP tailnet).
- [ ] Volume `/var/lib/m-data` cifrado (LUKS); keyfile `0400`.
- [ ] `.env` `0600`, fora do git; chaves só em env.
- [ ] Backups cifrados (rclone crypt ou SSE) + snapshots do volume.
- [ ] Redis sem porta pública (já é interno à rede do compose).
