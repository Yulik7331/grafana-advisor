#!/bin/bash

# Универсальный установщик системы мониторинга
# Совмещает функциональность Python и Bash скриптов

set -e

SCRIPT_VERSION="1.0"
TIMESTAMP=$(date -Iseconds)

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функции для вывода
print_banner() {
    echo -e "${BLUE}============================================================${NC}"
    echo -e "${BLUE}  УНИВЕРСАЛЬНЫЙ УСТАНОВЩИК СИСТЕМЫ МОНИТОРИНГА DOCKER${NC}"
    echo -e "${BLUE}============================================================${NC}"
    echo -e "${GREEN}Поддерживаемые компоненты:${NC}"
    echo "1. Grafana + Prometheus + cAdvisor (главный сервер)"
    echo "2. cAdvisor (агент для сбора метрик)"
    echo "3. Создать конфигурацию без установки"
    echo "4. Добавить агенты в существующую конфигурацию"
    echo "5. Показать статус системы"
    echo -e "${BLUE}------------------------------------------------------------${NC}"
    echo "Версия: $SCRIPT_VERSION | Время: $TIMESTAMP"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

# Проверка и установка зависимостей
install_docker() {
    if ! command -v docker &> /dev/null; then
        print_info "Устанавливаем Docker..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
        usermod -aG docker $USER
        if command -v systemctl &> /dev/null; then
            systemctl enable docker
            systemctl start docker
        elif command -v service &> /dev/null; then
            service docker start
        fi
        rm -f get-docker.sh
        print_success "Docker установлен"
    else
        print_success "Docker уже установлен"
    fi
}

install_docker_compose() {
    if ! command -v docker-compose &> /dev/null; then
        print_info "Устанавливаем Docker Compose..."
        COMPOSE_VERSION="v2.20.0"
        curl -L "https://github.com/docker/compose/releases/download/$COMPOSE_VERSION/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
        print_success "Docker Compose установлен"
    else
        print_success "Docker Compose уже установлен"
    fi
}

# Получение IP адреса
get_server_ip() {
    local detected_ip=$(hostname -I | awk '{print $1}')
    echo "Обнаружен IP: $detected_ip"
    read -p "Использовать этот IP? (y/n): " use_detected

    if [[ $use_detected == "y" || $use_detected == "Y" ]]; then
        SERVER_IP=$detected_ip
    else
        read -p "Введите IP сервера: " SERVER_IP
    fi
}

# Создание конфигурации основного сервера
create_main_server_config() {
    local grafana_password=$1
    local prometheus_targets=$2

    print_info "Создание конфигурации основного сервера..."

    # docker-compose.yml
    cat > docker-compose.yml << EOF
version: '3.8'

services:
  cadvisor:
    image: gcr.io/cadvisor/cadvisor:latest
    container_name: cadvisor
    ports:
      - "58080:8080"
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
      - /dev/disk/:/dev/disk:ro
    privileged: true
    devices:
      - /dev/kmsg:/dev/kmsg
    networks:
      - monitoring
    restart: unless-stopped
    command:
      - '--housekeeping_interval=30s'
      - '--docker_only=true'

  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    ports:
      - "59090:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--web.console.libraries=/usr/share/prometheus/console_libraries'
      - '--web.console.templates=/usr/share/prometheus/consoles'
      - '--web.enable-lifecycle'
      - '--storage.tsdb.retention.time=30d'
    networks:
      - monitoring
    restart: unless-stopped

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    ports:
      - "63000:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=$grafana_password
      - GF_USERS_ALLOW_SIGN_UP=false
      - GF_INSTALL_PLUGINS=grafana-piechart-panel
    volumes:
      - grafana_data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning
    networks:
      - monitoring
    restart: unless-stopped
    depends_on:
      - prometheus

volumes:
  prometheus_data:
  grafana_data:

networks:
  monitoring:
    driver: bridge
EOF

    # prometheus.yml
    cat > prometheus.yml << EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['prometheus:9090']

  - job_name: 'cadvisor'
    static_configs:
      - targets:
        - 'cadvisor:8080'           # Главный сервер (локальный)
$prometheus_targets
    scrape_interval: 5s
    metrics_path: /metrics
EOF

    # Создание директорий Grafana
    mkdir -p grafana/provisioning/datasources
    mkdir -p grafana/provisioning/dashboards

    # Настройка источника данных
    cat > grafana/provisioning/datasources/prometheus.yml << EOF
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    orgId: 1
    url: http://prometheus:9090
    basicAuth: false
    isDefault: true
    editable: true
EOF

    # Настройка дашбордов
    cat > grafana/provisioning/dashboards/dashboard.yml << EOF
apiVersion: 1

providers:
  - name: 'default'
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    allowUiUpdates: true
    options:
      path: /etc/grafana/provisioning/dashboards
EOF

    # Сохранение конфигурации
    cat > monitoring_config.json << EOF
{
  "install_type": "main_server",
  "server_ip": "$SERVER_IP",
  "grafana_password": "$grafana_password",
  "timestamp": "$TIMESTAMP",
  "version": "$SCRIPT_VERSION"
}
EOF

    print_success "Конфигурация создана"
}

# Создание скрипта агента
create_agent_script() {
    cat > agent-setup.sh << 'EOF'
#!/bin/bash

echo "🔧 Установка cAdvisor агента для мониторинга"
echo "============================================="

# Проверка Docker
if ! command -v docker &> /dev/null; then
    echo "⚙️  Устанавливаем Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    usermod -aG docker $USER
    if command -v systemctl &> /dev/null; then
        systemctl enable docker
        systemctl start docker
    fi
    echo "✅ Docker установлен"
else
    echo "✅ Docker уже установлен"
fi

# Остановка существующего cAdvisor
echo "🛑 Остановка существующего cAdvisor..."
docker stop cadvisor 2>/dev/null || true
docker rm cadvisor 2>/dev/null || true

# Запуск cAdvisor
echo "🚀 Запуск cAdvisor..."
docker run -d \
  --name=cadvisor \
  --restart=unless-stopped \
  -p 58080:8080 \
  -v /:/rootfs:ro \
  -v /var/run:/var/run:ro \
  -v /sys:/sys:ro \
  -v /var/lib/docker/:/var/lib/docker:ro \
  -v /dev/disk/:/dev/disk:ro \
  --privileged \
  --device=/dev/kmsg:/dev/kmsg \
  gcr.io/cadvisor/cadvisor:latest \
  --housekeeping_interval=30s \
  --docker_only=true

# Проверка запуска
sleep 5
if docker ps | grep -q cadvisor; then
    AGENT_IP=$(hostname -I | awk '{print $1}')
    echo "✅ cAdvisor успешно запущен!"
    echo "📊 Метрики доступны: http://$AGENT_IP:58080"
    echo "🔗 Или: http://localhost:58080"

    # Проверка метрик
    if curl -s http://localhost:58080/metrics | head -1 > /dev/null 2>&1; then
        echo "✅ Метрики работают корректно"
    else
        echo "⚠️  Внимание: Метрики недоступны"
    fi

    echo ""
    echo "🎯 ГОТОВО!"
    echo "=========="
    echo "Этот сервер теперь передает метрики на порту 58080"
    echo "Добавьте IP этого сервера в конфигурацию Prometheus:"
    echo "$AGENT_IP:58080"
else
    echo "❌ Ошибка запуска cAdvisor"
    echo "Логи:"
    docker logs cadvisor
    exit 1
fi
EOF
    chmod +x agent-setup.sh
    print_success "Скрипт агента создан"
}

# Установка основного сервера
install_main_server() {
    echo ""
    echo -e "${BLUE}🏗️  УСТАНОВКА ОСНОВНОГО СЕРВЕРА${NC}"
    echo "==============================="

    # Получение IP
    get_server_ip

    # Пароль Grafana
    read -p "Пароль для Grafana admin (по умолчанию: admin): " grafana_password
    grafana_password=${grafana_password:-admin}

    # Добавление агентов
    echo ""
    echo "Настройка агентов для мониторинга:"
    prometheus_targets=""
    while true; do
        read -p "Введите IP агента (Enter для завершения): " agent_ip
        if [[ -z "$agent_ip" ]]; then
            break
        fi
        prometheus_targets="$prometheus_targets        - '$agent_ip:58080'           # Agent $agent_ip\n"
        echo "Добавлен агент: $agent_ip:58080"
    done

    # Установка зависимостей
    install_docker
    install_docker_compose

    # Создание конфигурации
    create_main_server_config "$grafana_password" "$prometheus_targets"
    create_agent_script

    # Запуск сервисов
    echo ""
    print_info "Запуск сервисов..."
    docker-compose down 2>/dev/null || true
    docker-compose up -d

    echo ""
    print_success "ОСНОВНОЙ СЕРВЕР УСТАНОВЛЕН!"
    echo "============================="
    echo "🌐 Grafana:    http://$SERVER_IP:63000 (admin/$grafana_password)"
    echo "📈 Prometheus: http://$SERVER_IP:59090"
    echo "📊 cAdvisor:   http://$SERVER_IP:58080"
    echo ""
    echo "📋 Для добавления агентов:"
    echo "1. Скопируйте agent-setup.sh на другие сервера"
    echo "2. Запустите: sudo ./agent-setup.sh"
    echo "3. Добавьте IP агентов в prometheus.yml"
    echo "4. Перезагрузите Prometheus: curl -X POST http://$SERVER_IP:59090/-/reload"
}

# Установка агента
install_agent() {
    echo ""
    echo -e "${BLUE}🔧 УСТАНОВКА АГЕНТА${NC}"
    echo "=================="

    # Получение IP агента
    local agent_ip=$(hostname -I | awk '{print $1}')
    echo "IP этого агента: $agent_ip"

    # IP основного сервера
    read -p "Введите IP основного сервера: " main_server_ip

    # Установка Docker
    install_docker

    # Остановка существующего cAdvisor
    docker stop cadvisor 2>/dev/null || true
    docker rm cadvisor 2>/dev/null || true

    # Запуск cAdvisor
    print_info "Запуск cAdvisor..."
    docker run -d \
      --name=cadvisor \
      --restart=unless-stopped \
      -p 58080:8080 \
      -v /:/rootfs:ro \
      -v /var/run:/var/run:ro \
      -v /sys:/sys:ro \
      -v /var/lib/docker/:/var/lib/docker:ro \
      -v /dev/disk/:/dev/disk:ro \
      --privileged \
      --device=/dev/kmsg:/dev/kmsg \
      gcr.io/cadvisor/cadvisor:latest \
      --housekeeping_interval=30s \
      --docker_only=true

    # Проверка запуска
    sleep 5
    if docker ps | grep -q cadvisor; then
        echo ""
        print_success "АГЕНТ УСТАНОВЛЕН!"
        echo "=================="
        echo "📊 Метрики доступны: http://$agent_ip:58080"
        echo ""
        echo "📋 СЛЕДУЮЩИЕ ШАГИ:"
        echo "1. На основном сервере отредактируйте prometheus.yml"
        echo "2. Добавьте строку: - '$agent_ip:58080'"
        echo "3. Перезагрузите Prometheus: curl -X POST http://$main_server_ip:59090/-/reload"
        echo ""
        if curl -s http://localhost:58080/metrics | head -1 > /dev/null 2>&1; then
            print_success "Метрики работают корректно"
        else
            print_warning "Метрики недоступны"
        fi
    else
        print_error "Ошибка запуска cAdvisor"
        docker logs cadvisor
        exit 1
    fi
}

# Создание только конфигурации
create_config_only() {
    echo ""
    echo -e "${BLUE}📝 СОЗДАНИЕ КОНФИГУРАЦИИ${NC}"
    echo "========================"

    get_server_ip

    read -p "Пароль для Grafana admin (по умолчанию: admin): " grafana_password
    grafana_password=${grafana_password:-admin}

    echo ""
    echo "Добавление агентов:"
    prometheus_targets=""
    while true; do
        read -p "Введите IP агента (Enter для завершения): " agent_ip
        if [[ -z "$agent_ip" ]]; then
            break
        fi
        prometheus_targets="$prometheus_targets        - '$agent_ip:58080'           # Agent $agent_ip\n"
        echo "Добавлен агент: $agent_ip:58080"
    done

    create_main_server_config "$grafana_password" "$prometheus_targets"
    create_agent_script

    print_success "Конфигурация создана без установки"
    echo "Для запуска выполните: sudo docker-compose up -d"
}

# Добавление агентов в существующую конфигурацию
add_agents() {
    echo ""
    echo -e "${BLUE}➕ ДОБАВЛЕНИЕ АГЕНТОВ${NC}"
    echo "===================="

    if [[ ! -f "prometheus.yml" ]]; then
        print_error "Файл prometheus.yml не найден"
        echo "Сначала установите основной сервер или создайте конфигурацию"
        return 1
    fi

    echo "Текущая конфигурация:"
    grep -A 10 "job_name: 'cadvisor'" prometheus.yml

    echo ""
    while true; do
        read -p "Введите IP нового агента (Enter для завершения): " agent_ip
        if [[ -z "$agent_ip" ]]; then
            break
        fi

        # Добавление в prometheus.yml
        sed -i "/- 'cadvisor:8080'/a\\        - '$agent_ip:58080'           # Agent $agent_ip" prometheus.yml
        print_success "Агент $agent_ip:58080 добавлен"
    done

    echo ""
    echo "Обновленная конфигурация:"
    grep -A 15 "job_name: 'cadvisor'" prometheus.yml

    echo ""
    print_info "Для применения изменений выполните:"
    echo "curl -X POST http://localhost:59090/-/reload"
}

# Показать статус системы
show_status() {
    echo ""
    echo -e "${BLUE}📊 СТАТУС СИСТЕМЫ${NC}"
    echo "================"

    if command -v docker &> /dev/null; then
        print_success "Docker установлен"

        echo ""
        echo "Запущенные контейнеры:"
        docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" | grep -E "(cadvisor|prometheus|grafana|NAMES)"

        echo ""
        echo "Проверка портов:"
        for port in 58080 59090 63000; do
            if ss -tulpn | grep -q ":$port "; then
                print_success "Порт $port открыт"
            else
                print_warning "Порт $port закрыт"
            fi
        done

        if [[ -f "prometheus.yml" ]]; then
            echo ""
            echo "Конфигурация Prometheus:"
            grep -A 20 "job_name: 'cadvisor'" prometheus.yml
        fi

        if [[ -f "monitoring_config.json" ]]; then
            echo ""
            echo "Информация об установке:"
            cat monitoring_config.json | python3 -m json.tool 2>/dev/null || cat monitoring_config.json
        fi
    else
        print_warning "Docker не установлен"
    fi
}

# Главное меню
main_menu() {
    while true; do
        print_banner
        echo ""
        echo "Выберите действие:"
        echo "1. Установить основной сервер (Grafana + Prometheus + cAdvisor)"
        echo "2. Установить агент (только cAdvisor)"
        echo "3. Создать конфигурацию без установки"
        echo "4. Добавить агенты в существующую конфигурацию"
        echo "5. Показать статус системы"
        echo "6. Выход"
        echo ""

        read -p "Ваш выбор (1-6): " choice

        case $choice in
            1)
                install_main_server
                break
                ;;
            2)
                install_agent
                break
                ;;
            3)
                create_config_only
                break
                ;;
            4)
                add_agents
                ;;
            5)
                show_status
                echo ""
                read -p "Нажмите Enter для продолжения..."
                ;;
            6)
                echo "Выход..."
                exit 0
                ;;
            *)
                print_error "Неверный выбор. Введите число от 1 до 6."
                echo ""
                read -p "Нажмите Enter для продолжения..."
                ;;
        esac
    done
}

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
    print_error "Скрипт должен запускаться с правами root"
    echo "Используйте: sudo $0"
    exit 1
fi

# Запуск главного меню
main_menu
