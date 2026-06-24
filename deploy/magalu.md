# Deploy do M-Engine 24h na Magalu Cloud (VM + systemd + `cc`)

Runbook para rodar o M-Engine numa **Máquina Virtual** da Magalu Cloud, com dados num
**Block Storage** cifrado, acesso **privado via Tailscale**, **backup** num **bucket Object Storage**
nativo, e os LLMs servidos pela **assinatura Claude (Code) via `cc`** — sem crédito de API.

> **Conceitos.** A *VM* roda os processos (compute, descartável). O *Block Storage* é um SSD
> anexado à VM e montado como pasta (`/var/lib/m-data`) — guarda o estado clínico vivo (PHI). O
> *Object Storage (bucket, protocolo S3 — produto nativo Magalu, não AWS)* guarda backups. Se a VM
> morrer, recria-se sem perder dado: o estado mora no volume, não na VM.

> **Por que systemd no host (e não Docker):** o provider `cc` roda `claude -p` reaproveitando a
> **auth do sistema** (assinatura Max logada no host). Dentro de um container o `claude` e a auth não
> existem, então o `cc` não funciona. Rodando como o usuário logado (`ubuntu`), o `cc` serve **todos
> os stages** sem custo de API. O assistente do app usa a **API** (Sonnet 4.6) — mantenha
> `ANTHROPIC_API_KEY` no `/etc/m-engine.env`. **Este é o único runtime suportado; Docker foi descontinuado.**

```
Mac / iPhone (app SwiftUI) ──Tailnet 100.x──▶ VM Magalu (Ubuntu)
                                              ├─ systemd: m-engine-api (uvicorn) · m-engine-worker (celery) · redis
                                              │     LLMs via `cc` (assinatura Claude, M_FORCE_MODEL=cc)
                                              └─ /var/lib/m-data  (Block, cifrado pelo provider)
                                                 ├─ pat/    (dossiês PHI)
                                                 └─ audio/  (uploads + transcrições)
                                                      └─ mgc objects sync ─▶ bucket m-engine-backups
```

Comandos rodam **na VM** (SSH), salvo onde indicado. O usuário de serviço é **`ubuntu`** (onde a
assinatura Claude está logada).

---

## 1. Provisionar recursos (`mgc` CLI ou painel)

1. **VM**: Ubuntu, **≥ 4 vCPU / 8 GB RAM**.
2. **Block Storage** (volume cifrado, mesma AZ da VM) — via `mgc` na sua estação:
   ```bash
   VM=$(mgc virtual-machine instances list -o json | jq -r '.instances[0].id')   # ou copie o id
   mgc block-storage volumes create --name m-data --size 100 \
       --type.name cloud_nvme5k --availability-zone br-se1-a --encrypted
   VOL=$(mgc block-storage volumes list -o json | jq -r '.volumes[]|select(.name=="m-data").id')
   mgc block-storage volumes attach --id "$VOL" --virtual-machine-id "$VM"
   ```
   O volume aparece na VM como novo disco (ex.: `/dev/vdb`, confirme com `lsblk`).
3. **Object Storage**: o bucket é criado no §6 com o próprio `mgc` (nativo Magalu, **não é AWS**).

---

## 2. Preparar a VM (SO + deps + Claude Code)

```bash
sudo apt update && sudo apt -y upgrade
sudo apt -y install git python3-venv python3-pip redis-server
sudo systemctl enable --now redis-server          # broker/result-backend local do Celery

# Claude Code (provider cc) — instale como o usuário `ubuntu` (não root):
curl -fsSL https://claude.ai/install.sh | bash     # instala em ~/.local/bin/claude
claude auth login                                  # autentique na sua conta (assinatura Max)
claude auth status                                 # confira loggedIn:true / subscriptionType
```

> O **Block Storage** já é **cifrado em repouso** pelo provider (`--encrypted` no §1) — sem LUKS
> (menos fragilidade no boot). Quem quiser uma 2ª camada pode aplicar LUKS por cima.

---

## 3. Formatar e montar o Block (cifrado pelo provider)

```bash
lsblk                                    # o volume anexado aparece como novo disco (ex.: /dev/vdb)
DEV=/dev/vdb
sudo blkid "$DEV" || echo "vazio — ok p/ formatar"   # confirme VAZIO (não é o /dev/vda do SO!)

sudo mkfs.ext4 -q -L m-data "$DEV"
sudo mkdir -p /var/lib/m-data
sudo mount "$DEV" /var/lib/m-data
sudo chown -R ubuntu:ubuntu /var/lib/m-data          # os serviços rodam como ubuntu

# Remontar no boot via fstab (por UUID; nofail evita travar o boot se faltar)
UUID=$(sudo blkid -s UUID -o value "$DEV")
echo "UUID=$UUID  /var/lib/m-data  ext4  defaults,nofail  0  2" | sudo tee -a /etc/fstab
sudo umount /var/lib/m-data && sudo mount -a && mountpoint /var/lib/m-data   # testa o fstab
```

---

## 4. Rede privada (Tailscale)

```bash
curl -fsSL https://tailscale.com/install.sh | sudo sh
sudo tailscale up                         # autentique a VM na sua tailnet (abra a URL no navegador)
tailscale ip -4                           # anote o IP 100.x.y.z da VM
```

- Instale o Tailscale também no **Mac** e no **iPhone** (mesma conta/tailnet).
- **Firewall / Security Group da Magalu**: **não abra a porta 8000** para a internet. A API liga só no
  IP da tailnet (abaixo). O Tailscale não precisa de porta inbound aberta.

---

## 5. Subir o m-engine (host / systemd, rodando na assinatura `cc`)

```bash
# código + venv (como ubuntu)
sudo git clone https://github.com/myselfgus/m.git /opt/m-engine
sudo chown -R ubuntu:ubuntu /opt/m-engine
python3 -m venv /home/ubuntu/m-venv
/home/ubuntu/m-venv/bin/pip install -U pip
/home/ubuntu/m-venv/bin/pip install /opt/m-engine      # instala o pacote (CLI `m`, api, worker)

# EnvironmentFile (segredos, 0600, root) — fonte única de config dos serviços
sudo tee /etc/m-engine.env >/dev/null <<'ENV'
M_BASE=/var/lib/m-data
ELEVENLABS_API_KEY=__sua_chave__
M_CLAUDE_CLI_BIN=/home/ubuntu/.local/bin/claude
M_FORCE_MODEL=cc                 # força TODOS os stages na assinatura (sem crédito de API)
REDIS_URL=redis://localhost:6379/0
M_API_HOST=100.x.y.z             # IP da tailnet → API privada
M_API_PORT=8000
M_CACHE_TTL=1h
ENV
sudo chmod 600 /etc/m-engine.env

# serviços systemd (rodam como ubuntu; bind na tailnet; restart always)
sudo cp deploy/systemd/m-engine-api.service deploy/systemd/m-engine-worker.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now m-engine-worker m-engine-api
```

> **`M_FORCE_MODEL=cc`** faz `normalize`/`birp`/`asl`/`dimensional`/`gem`/`soap_*` usarem o `cc`
> (assinatura). Sem essa var, cada stage usa seu default de API (sonnet/opus) — aí precisaria de
> crédito Anthropic. O prewarm vira no-op com `cc` (sem chamadas/erros de crédito no boot).

---

## 6. Backup para o bucket (Object Storage nativo Magalu, via `mgc`)

> O Object Storage é **produto nativo da Magalu** (br-se1) — sem AWS, sem rclone.

```bash
# mgc na VM (binário nativo) + credencial de Object Storage (key pair estática)
# (já costuma vir instalado; senão: curl -fsSL .../mgccli/.../install.sh | sudo bash)
mgc object-storage api-key set --uuid <uuid-da-sua-key>   # mgc object-storage api-key list
mgc object-storage buckets create --bucket m-engine-backups --private --enable-versioning

# cron (root): backup noturno 03:30 (replicar a credencial p/ /root/.config/mgc se rodar como root)
echo '30 3 * * * root M_BASE=/var/lib/m-data BUCKET=m-engine-backups /opt/m-engine/deploy/backup.sh >> /var/log/m-backup.log 2>&1' | sudo tee /etc/cron.d/m-backup
sudo M_BASE=/var/lib/m-data BUCKET=m-engine-backups /opt/m-engine/deploy/backup.sh   # dry run
```

Confira: `mgc object-storage objects list --bucket m-engine-backups/pat`. Agende também
**snapshots do volume Block** no painel/`mgc` (defesa extra). O volume já é cifrado em repouso.

---

## 7. App SwiftUI

- Em **Ajustes**, aponte a URL para `http://100.x.y.z:8000` (IP Tailscale da VM, ou o nome MagicDNS) e
  use "Testar conexão". No seletor de modelo, **Padrão** já roda via `cc` (por causa do `M_FORCE_MODEL`).
- O `Info.plist` já tem `NSAllowsLocalNetworking`. Se o iOS bloquear o IP 100.x, adicione exceção
  `NSExceptionDomains` para o host tailnet (ou use o nome MagicDNS).

---

## 8. Verificação (end-to-end)

```bash
# 1) serviços de pé; worker conectado ao redis + prewarm sem erro de crédito
systemctl is-active redis-server m-engine-worker m-engine-api
sudo journalctl -u m-engine-worker -n 20 --no-pager | grep -iE "ready|prewarm|connected"

# 2) healthz pela tailnet (do Mac); da internet pública deve FALHAR
curl -fsS http://100.x.y.z:8000/healthz        # {"status":"ok","m_base":"/var/lib/m-data"}

# 3) pipeline real via API (caminho de produção): upload -> job -> polling
curl -sS -F file=@sessao.m4a http://100.x.y.z:8000/audio
curl -sS -X POST http://100.x.y.z:8000/jobs/pipeline -H 'content-type: application/json' \
  -d '{"audio_path":"/var/lib/m-data/audio/sessao.m4a","deep":true}'
# GET /jobs/<id> até ready; depois /patients e /patients/<id>/documents
```

4. **Backup**: `backup.sh` + `mgc object-storage objects list --bucket m-engine-backups/pat`.
5. **Resiliência**: `sudo reboot` → volume remonta via `fstab`, serviços sobem sozinhos
   (`restart=always`, `After=tailscaled`), dados persistem, `/healthz` volta sem intervenção.

---

## Operação do dia a dia

```bash
sudo journalctl -u m-engine-api -u m-engine-worker -f          # logs
# atualizar: git pull + reinstalar o pacote no venv + reiniciar
cd /opt/m-engine && git pull && /home/ubuntu/m-venv/bin/pip install --force-reinstall --no-deps . \
  && sudo systemctl restart m-engine-worker m-engine-api
# renovar a sessão cc, se expirar:  claude auth login   (como ubuntu)
```

## Segurança (PHI) — checklist

- [ ] API **não** exposta publicamente (Tailscale; uvicorn liga só em `M_API_HOST` = IP tailnet).
- [ ] Volume `/var/lib/m-data` cifrado em repouso (provider `--encrypted`).
- [ ] `/etc/m-engine.env` `0600` (segredos só aí); nada de chave no git.
- [ ] Backups versionados no bucket privado + snapshots do volume.
- [ ] Redis só em `localhost` (sem porta pública).
- [ ] systemd hardening: `NoNewPrivileges`, `PrivateTmp`, `ProtectSystem=strict`, `ReadWritePaths=/var/lib/m-data`.
