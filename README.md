# infra-showcase

Инфраструктура небольшого продакшен-проекта: Dockerized PHP-приложение на VPS,
CI/CD, мониторинг, централизованное логирование, алертинг и hardening.
Всё описано как код и разворачивается из этого репозитория.

> Конфиги взяты из реально работающей системы. Секреты, IP и домены заменены
> на переменные и плейсхолдеры (`*.example`, `vps.example.com`, `app.example.com`).

## Архитектура

```mermaid
flowchart LR
  subgraph VPS["VPS (Ubuntu 22.04)"]
    caddy[Caddy<br/>TLS, reverse proxy] --> web[App<br/>Apache + PHP]
    web --> db[(MariaDB)]
    ne[node_exporter] --> vma[vmagent<br/>disk buffer]
    cad[cAdvisor] --> vma
    logs[Docker logs<br/>journald<br/>fail2ban.log] --> alloy[Grafana Alloy]
    f2b[fail2ban] -.-> logs
  end

  subgraph MON["Monitoring host"]
    prom[Prometheus] --> graf[Grafana]
    loki[Loki] --> graf
    prom --> am[Alertmanager]
    graf -->|log-based alerts| am
  end

  vma -->|remote_write<br/>reverse SSH tunnel| prom
  alloy -->|push<br/>reverse SSH tunnel| loki
  am --> tg[Telegram]

  gl[GitLab CI / GitHub Actions] -->|build & push image| reg[(GitLab Registry)]
  gl -->|Ansible deploy| VPS
```

Хост мониторинга не имеет публичного адреса. Связь с ним идёт через
reverse SSH-туннели, которые он сам поднимает к VPS. Ни один порт мониторинга
не открыт в интернет.

## Стек

| Область | Инструменты |
|---|---|
| Контейнеры | Docker, Docker Compose, GitLab Container Registry |
| CI/CD | GitLab CI, GitHub Actions, Ansible |
| Метрики | Prometheus, vmagent (VictoriaMetrics), node_exporter, cAdvisor |
| Логи | Grafana Loki, Grafana Alloy |
| Свои экспортёры | Bash, Docker, node_exporter textfile collector |
| Визуализация и алерты | Grafana, Alertmanager → Telegram |
| Kubernetes | k3s (k3d), Helm, ArgoCD (GitOps), Traefik Ingress, ServiceLB |
| Прокси и TLS | Caddy (автоматический Let's Encrypt) |
| Безопасность | SSH только по ключам, fail2ban, ограниченные SSH-ключи |
| ОС | Ubuntu, systemd |

## Структура

```
app/                    Dockerfile, docker-compose, Caddyfile, systemd-таймеры
ansible/                плейбук деплоя приложения
ci/                     пайплайны: сборка образа, линт + деплой, GitHub Actions
monitoring-central/     Prometheus, Grafana, Loki, Alertmanager, дашборды, правила
  lan-scanner/          самописный экспортёр устройств в LAN (textfile collector)
monitoring-agent/       то, что стоит на VPS: vmagent, Alloy, экспортёры
  security/             fail2ban, sshd hardening, пример ограниченного ключа
tunnels/                systemd-юниты SSH-туннелей
k8s/                    перенос приложения в Kubernetes
  chart/                Helm-чарт: MariaDB (StatefulSet + PVC), web, Ingress, TCP LoadBalancer
  argocd/               Application (auto-sync, self-heal, prune) и Ingress для UI
  Dockerfile.k8s        образ с кодом приложения
```

## Kubernetes и GitOps

Приложение перенесено из Docker Compose в Kubernetes (k3s) и деплоится по модели GitOps:

```
git push (код приложения)
 └─ GitLab CI на self-hosted runner
      lint → сборка образа app/k8s:<commit-sha> → GitLab Container Registry
                └─ job bump: записывает новый тег в репозиторий с чартом
                              └─ ArgoCD видит коммит → rolling update в кластере
```

Кластеру не нужен входящий доступ: ArgoCD сам забирает изменения из git.
Ручные правки в кластере (`kubectl scale`, `edit`) ArgoCD откатывает к состоянию из git (self-heal).

**Ключевые решения:**

- **MariaDB в StatefulSet с PersistentVolumeClaim.** Под получает стабильное имя `db-0`
  и всегда тот же том. Данные переживают удаление пода, переустановку чарта и смену
  инструмента деплоя (kubectl → Helm → ArgoCD).
- **Код запечён в образ, тег = хэш коммита.** Никаких `latest`: каждая версия однозначно
  связана с коммитом, откат — смена тега в git.
- **Конфигурация из окружения.** Один образ работает на VPS и в кластере; пароли —
  в Kubernetes Secrets и не попадают в git.
- **Корректная остановка.** Apache запускается как PID 1 (не через `apachectl`)
  с `STOPSIGNAL SIGWINCH`: при rolling update текущие запросы дорабатываются,
  под завершается за ~1 с вместо SIGKILL по таймауту.
- **GPS-трекеры по сырому TCP** выведены через Service типа LoadBalancer,
  HTTP — через Traefik Ingress с маршрутизацией по имени хоста.
- **Self-hosted GitLab Runner** (Docker executor) — сборки не зависят от очередей
  и сбоев общих раннеров, кеш слоёв переиспользуется.

## Ключевые решения

**Метрики не теряются при недоступности хоста мониторинга.**
vmagent на VPS собирает метрики локально и отправляет их через `remote_write`.
Пока хост мониторинга недоступен, данные копятся на диске, а после восстановления
связи досылаются.

**Объём метрик снижен примерно в 7 раз.**
В vmagent настроен relabeling: отбрасываются неиспользуемые серии и лейблы
(см. `monitoring-agent/vmagent/scrape.yml`).

**Логи с разбором времени.**
Alloy собирает логи Docker-контейнеров, journald и fail2ban. Для fail2ban
временная метка парсится из строки лога с учётом часового пояса сервера,
так что в Loki события лежат с реальным временем, а не со временем чтения.

**Безопасность туннелей.**
Ключ, которым хост мониторинга подключается к VPS, ограничен:
`restrict,port-forwarding,permitlisten=...,command="/bin/false"`.
Через него нельзя получить shell, можно только открыть разрешённые порты
(см. `monitoring-agent/security/tunnel-authorized_keys.example`).

**Мониторинг Wi-Fi устройств домашней сети.**
Самописный экспортёр `lan-scanner` (shell-скрипт в контейнере) сканирует LAN,
сопоставляет MAC-адреса с понятными именами (`names.txt`) и пишет метрики
в формате Prometheus в textfile collector node_exporter. В Grafana есть дашборд
с количеством подключённых устройств и их присутствием во времени
(`monitoring-central/dashboards/`).

**Алерты по логам.**
Правило в Grafana считает баны fail2ban в Loki и отправляет их в Alertmanager.
Отдельный маршрут группирует алерты по IP: одно сообщение на один бан,
без повторов и без resolved-шума.

## CI/CD

1. `ci/gitlab-ci.image-build.yml`: сборка образа, push в GitLab Registry,
   обновление контейнера на сервере.
2. `ci/gitlab-ci.app-deploy.yml`: `php -l` по всем файлам, затем деплой через Ansible.
3. `ci/github-actions/`: тот же деплой на GitHub Actions.

Переменные задаются в настройках CI:

| Переменная | Назначение |
|---|---|
| `SSH_KEY` / `SSH_PRIVATE_KEY` | ключ деплоя (base64) |
| `DEPLOY_HOST` | адрес сервера |
| `DEPLOY_PATH` | каталог проекта на сервере |
| `APP_REPO` | репозиторий приложения |

## Запуск

```bash
# хост мониторинга
cd monitoring-central
cp .env.example .env               # задать пароль Grafana
echo "<bot token>" > telegram_token
docker compose up -d

# туннели
cp tunnels/*.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now vps-tunnel vps-metrics-tunnel

# VPS: агенты
cd monitoring-agent && docker compose up -d
cd alloy && docker compose up -d

# VPS: приложение
cd app && cp .env.example .env && docker compose up -d
```

## Дальше

- [x] перенести приложение в Kubernetes (k3s), Helm-чарт, GitOps через ArgoCD
- [ ] TLS в кластере через cert-manager, мониторинг кластера (kube-prometheus-stack)
- [ ] инфраструктура VPS через Terraform
- [ ] роли Ansible для агентов мониторинга и hardening
