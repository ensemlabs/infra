# COCOTECH infra playbook

Hướng dẫn dựng lại stack infra nhà: **hai Docker daemon**, **WireGuard qua VPS**, rồi **MinIO → Langfuse → LiteLLM**.

Repo này chỉ chứa playbook (skill + template). Không chứa `.env`, private key, hay data Docker.

Trên máy đang chạy, cây live mặc định là `/mnt/d/infra` (chmod 700). Repo GitHub và cây live có thể cùng một thư mục — `.gitignore` chặn data/secret.

## Cài skill vào Cursor

Skill **không** nằm trong `.cursor/skills` của repo. Phải copy vào chỗ Cursor đọc.

### Cách 1 — mọi project (khuyên dùng)

```bash
git clone git@github.com:COCOTECH-Labs/infra.git
cd infra
./scripts/install-skills.sh
```

Copy 6 skill vào `~/.cursor/skills/`. Mở lại cửa sổ Cursor.

### Cách 2 — chỉ một repo

```bash
./scripts/install-skills.sh --project /path/to/your-repo
```

Copy vào `/path/to/your-repo/.cursor/skills/`. Đừng commit thư mục đó nếu repo kia không phải playbook.

### Cách 3 — copy tay

```bash
mkdir -p ~/.cursor/skills
cp -a skills/* ~/.cursor/skills/
```

Không copy vào `~/.cursor/skills-cursor/` — đó là skill built-in của Cursor.

Sau khi cài, bảo agent: **apply infra-stack**. Agent sẽ đọc lần lượt các skill con.

## Sáu skill

| Skill | Việc |
|--------|------|
| `infra-stack` | Bản đồ, `site.env`, thứ tự, rule cứng |
| `split-infra-docker` | Tách `docker` (DEV) và `docker-infra` (INFRA) |
| `setup-wireguard` | Home `10.66.0.2` ↔ VPS `10.66.0.1`, `wg-forward` |
| `setup-minio` | S3, bucket, access key theo app |
| `setup-langfuse` | Tracing, Postgres/Redis/ClickHouse riêng |
| `setup-litellm` | LLM proxy, `/ui`, trace sang Langfuse |

Thứ tự: **docker split → WireGuard → MinIO → Langfuse → LiteLLM**.

Template đi kèm từng skill (`skills/<tên>/templates/`). Agent copy template, điền `site.env`, sinh secret mới — không bịa topology.

## Topology

```
Internet → VPS
            WireGuard 10.66.0.1  UDP 51820
            DNAT, không MASQUERADE
                 ↓
Home wg0 10.66.0.2
  docker            DEV    /run/docker.sock
  docker-infra      INFRA  /run/docker-infra.sock
       minio :9000/:9001   langfuse :3000   litellm :4000
```

Cổng public trên VPS: `2222→2486` (SSH nhà), `9100→9000`, `9101→9001`, `3100→3000`, `4000→4000`.

## Rule cứng

- Hai process `dockerd`. Không gắn hai socket vào một daemon.
- Không `systemctl restart docker` (daemon DEV).
- Không tắt password SSH trên VPS.
- Không MASQUERADE forward WireGuard.
- Không commit `.env`, `*.key`, `docker/`, `containerd/`, `*/data/`.

Chi tiết cho agent: [AGENTS.md](AGENTS.md).
