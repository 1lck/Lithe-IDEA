const toast = document.querySelector('#toast');
const sourceCode = document.querySelector('#sourceCode code');
const lineGutter = document.querySelector('#lineGutter');
const foldGutter = document.querySelector('#foldGutter');
const toolWindow = document.querySelector('#toolWindow');
const toolBody = document.querySelector('#toolBody');
let toastTimer;

const fileModels = {
  'BusinessCommonApplication.java': {
    symbol: 'BA',
    breadcrumb: 'BusinessCommonApplication',
    content: `package net.deeperception;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication(exclude = {
    DataSourceAutoConfiguration.class,
    KafkaAutoConfiguration.class
})
@EnableKafka
@EnableScheduling
@RefreshScope
@EnableFeignClients({"net.deeperception.*", "com.dji.biz.*"})
@ComponentScan({"com.dji", "net.deeperception"})
@MapperScan("com.dji.biz.*.dao")
@EnableConfigurationProperties
@EnableRetry
@EnableTransactionManagement
public class BusinessCommonApplication {

    public static void main(String[] args) {
        SpringApplication.run(BusinessCommonApplication.class, args);
    }
}`,
  },
  'OfflineListener.java': {
    symbol: 'OL',
    breadcrumb: 'OfflineListener',
    content: `package net.deeperception.business.listener;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.stereotype.Component;

@Slf4j
@Component
@RequiredArgsConstructor
public class OfflineListener {

    private final DeviceHandler deviceHandler;

    @KafkaListener(topics = "device-offline", groupId = "business-common")
    public void handle(DeviceOfflineEvent event) {
        log.info("device offline: {}", event.deviceId());
        deviceHandler.markOffline(event.deviceId(), event.occurredAt());
    }
}`,
  },
  'DeviceHandler.java': {
    symbol: 'DH',
    breadcrumb: 'DeviceHandler',
    content: `package net.deeperception.business.device;

import java.time.Instant;
import org.springframework.stereotype.Service;

@Service
public class DeviceHandler {

    private final DeviceRepository repository;

    public DeviceHandler(DeviceRepository repository) {
        this.repository = repository;
    }

    public void markOffline(String deviceId, Instant occurredAt) {
        Device device = repository.findRequired(deviceId);
        device.markOffline(occurredAt);
        repository.save(device);
    }
}`,
  },
  'DockOfflineScheduled.java': {
    symbol: 'DO',
    breadcrumb: 'DockOfflineScheduled',
    content: `package net.deeperception.business.schedule;

import lombok.RequiredArgsConstructor;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

@Component
@RequiredArgsConstructor
public class DockOfflineScheduled {

    private final DockMonitor dockMonitor;

    @Scheduled(fixedDelayString = "\${dock.offline.delay:30000}")
    public void inspectDockState() {
        dockMonitor.refreshOfflineDevices();
    }
}`,
  },
  'TaskDispatcher.java': {
    symbol: 'TD',
    breadcrumb: 'TaskDispatcher',
    content: `package net.deeperception.task;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class TaskDispatcher {

    private final ExecutorService executor = Executors.newVirtualThreadPerTaskExecutor();

    public void dispatch(Runnable task) {
        executor.submit(task);
    }

    public void shutdown() {
        executor.shutdown();
    }
}`,
  },
  'ErrorCodeEnum.java': {
    symbol: 'EC',
    breadcrumb: 'ErrorCodeEnum',
    content: `package net.deeperception.common;

public enum ErrorCodeEnum {
    DEVICE_NOT_FOUND("BIZ-404", "Device does not exist"),
    DEVICE_OFFLINE("BIZ-409", "Device is offline"),
    INTERNAL_ERROR("SYS-500", "Internal server error");

    private final String code;
    private final String message;

    ErrorCodeEnum(String code, String message) {
        this.code = code;
        this.message = message;
    }
}`,
  },
  'pom.xml': {
    symbol: 'XML',
    breadcrumb: 'pom.xml',
    content: `<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>net.deeperception</groupId>
  <artifactId>business-common-api</artifactId>
  <version>2.4.0</version>

  <properties>
    <java.version>21</java.version>
    <spring-boot.version>3.4.2</spring-boot.version>
  </properties>
</project>`,
  },
  'README.md': {
    symbol: 'MD',
    breadcrumb: 'README',
    content: `# query-statistics

Business statistics and device-event aggregation service.

## Local development

1. Start PostgreSQL and Kafka.
2. Configure the local profile.
3. Run BusinessCommonApplication.

The service listens on port 8080 by default.`,
  },
  'AGENTS.md': {
    symbol: 'MD',
    breadcrumb: 'AGENTS',
    content: `# Workspace guidance

- Keep changes scoped to the requested module.
- Run focused tests before handing off.
- Preserve existing project conventions.
- Document commands that modify generated files.`,
  },
};

const toolViews = {
  run: `<div class="run-line"><span class="live"></span><strong>BusinessCommonApplication</strong><span class="run-label">运行中 · 00:00:12</span><span class="tool-fill"></span><button class="stop" data-action="stop">■ 停止</button></div><div class="console"><p><time>13:04:11.232</time> <b>INFO</b> Started <mark>BusinessCommonApplication</mark> in 3.426 seconds</p><p><time>13:04:11.247</time> <b>INFO</b> Netty server listening on <em>:8080</em></p><p><time>13:04:12.019</time> <b>INFO</b> Ready to accept requests</p><p class="prompt">› <i></i></p></div>`,
  debug: `<div class="debug-layout"><aside><strong>Threads</strong><button class="debug-row selected">main</button><button class="debug-row">Reference Handler</button><button class="debug-row">Finalizer</button></aside><section><strong>Frames</strong><button class="debug-row selected">BusinessCommonApplication.main:28</button><button class="debug-row">NativeMethodAccessorImpl.invoke0</button></section><section><strong>Variables</strong><p>args = String[0]</p><p>applicationContext = AnnotationConfigApplicationContext</p></section></div>`,
  git: `<div class="git-layout"><aside><strong>Local Changes</strong><button class="change-row selected"><span class="modified">M</span> pom.xml</button><button class="change-row"><span class="added">A</span> OfflineListener.java</button></aside><section class="diff-preview"><div class="diff-head">pom.xml <span>Modified</span></div><p class="removed">- &lt;java.version&gt;17&lt;/java.version&gt;</p><p class="added-line">+ &lt;java.version&gt;21&lt;/java.version&gt;</p></section></div>`,
  terminal: `<div class="terminal"><p><span class="terminal-path">query-statistics</span> <span class="terminal-branch">git:(feat/V2.4.0)</span> $ ./mvnw spring-boot:run</p><p>[INFO] Scanning for projects...</p><p>[INFO] Building business-common-api 2.4.0</p><p class="prompt">› <i></i></p></div>`,
  problems: `<div class="problems-empty"><span>✓</span><strong>No problems found</strong><p>Project analysis completed successfully.</p></div>`,
};

function notify(message) {
  toast.textContent = message;
  toast.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toast.classList.remove('show'), 1400);
}

function escapeHTML(value) {
  return value.replace(/[&<>]/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' })[char]);
}

function highlightJavaLine(line) {
  const pattern = /(\/\/.*$)|("(?:\\.|[^"\\])*")|(@[A-Za-z_$][\w$]*)|\b(package|import|public|private|protected|class|interface|enum|record|static|final|void|return|new|extends|implements|throws|throw|if|else|try|catch|for|while|boolean|int|long|var)\b|\b([A-Z][A-Za-z0-9_$]*)\b|\b(\d+)\b/g;
  let html = '';
  let cursor = 0;
  for (const match of line.matchAll(pattern)) {
    html += escapeHTML(line.slice(cursor, match.index));
    const value = escapeHTML(match[0]);
    if (match[1]) html += `<span class="comment">${value}</span>`;
    else if (match[2]) html += `<span class="str">${value}</span>`;
    else if (match[3]) html += `<span class="annotation">${value}</span>`;
    else if (match[4]) html += `<span class="kw">${value}</span>`;
    else if (match[5]) html += `<span class="type">${value}</span>`;
    else html += `<span class="const">${value}</span>`;
    cursor = match.index + match[0].length;
  }
  return html + escapeHTML(line.slice(cursor));
}

function highlightLine(line, file) {
  if (file.endsWith('.java')) return highlightJavaLine(line);
  if (file.endsWith('.xml')) {
    return escapeHTML(line)
      .replace(/(&lt;\/?)([\w.-]+)/g, '$1<span class="type">$2</span>')
      .replace(/(&quot;.*?&quot;)/g, '<span class="str">$1</span>');
  }
  if (line.startsWith('#')) return `<span class="type">${escapeHTML(line)}</span>`;
  if (/^\d+\./.test(line) || line.startsWith('- ')) return `<span class="annotation">${escapeHTML(line)}</span>`;
  return escapeHTML(line);
}

function renderFile(file) {
  const model = fileModels[file] || {
    symbol: file.slice(0, 2).toUpperCase(),
    breadcrumb: file.replace(/\.[^.]+$/, ''),
    content: `// ${file}\n\n// File preview is ready for the workspace adapter.`,
  };
  const lines = model.content.split('\n');
  sourceCode.innerHTML = lines.map((line) => highlightLine(line, file)).join('\n');
  lineGutter.innerHTML = `<span class="gutter-spacer"></span>${lines.map((_, index) => `<span>${index + 1}</span>`).join('')}`;
  foldGutter.innerHTML = `<span class="gutter-spacer"></span>${lines.map((line) => `<span>${/[{>]\s*$/.test(line.trim()) ? '⌄' : ''}</span>`).join('')}`;
  document.querySelector('#breadcrumb').textContent = model.breadcrumb;
  document.querySelector('#windowFileName').textContent = file;
  document.querySelector('#documentAvatar').textContent = model.symbol;
  document.title = `${file} — Lithe-IDEA`;
  document.querySelector('#sourceCode').scrollTop = 0;

  const minimap = document.querySelector('.minimap');
  minimap.innerHTML = lines.slice(0, 26).map((line) => `<span style="width:${Math.max(12, Math.min(48, line.trim().length * 1.15))}px"></span>`).join('');
}

function fileIcon(file) {
  if (file.endsWith('.java')) return ['java-icon', 'J'];
  if (file.endsWith('.xml')) return ['xml-icon', '‹›'];
  return ['md-icon', 'M'];
}

function openFile(file, shouldNotify = true) {
  document.querySelectorAll('.file-row').forEach((item) => item.classList.toggle('selected', item.dataset.file === file));
  let tab = [...document.querySelectorAll('.editor-tab')].find((item) => item.dataset.file === file);
  if (!tab) {
    const [iconClass, iconLabel] = fileIcon(file);
    tab = document.createElement('button');
    tab.className = 'editor-tab';
    tab.dataset.file = file;
    tab.innerHTML = `<span class="${iconClass}">${iconLabel}</span><span>${file}</span><i>×</i>`;
    document.querySelector('#editorTabs').insertBefore(tab, document.querySelector('.new-tab'));
  }
  document.querySelectorAll('.editor-tab').forEach((item) => item.classList.toggle('selected', item === tab));
  renderFile(file);
  if (shouldNotify) notify(`打开 ${file}`);
}

function closeTab(tab) {
  const wasSelected = tab.classList.contains('selected');
  const siblings = [...document.querySelectorAll('.editor-tab')];
  const index = siblings.indexOf(tab);
  if (siblings.length === 1) {
    notify('至少保留一个编辑器标签');
    return;
  }
  tab.remove();
  if (wasSelected) {
    const fallback = siblings[index - 1] || siblings[index + 1];
    openFile(fallback.dataset.file, false);
  }
}

function renderTool(tool) {
  document.querySelectorAll('.tool-tab').forEach((item) => item.classList.toggle('selected', item.dataset.tool === tool));
  toolBody.innerHTML = toolViews[tool] || toolViews.run;
  toolWindow.classList.remove('collapsed');
  toolWindow.style.height = `${Math.max(190, Number(localStorage.getItem('lithe-tool-height')) || 230)}px`;
}

function handleAction(action) {
  if (action === 'welcome') {
    document.querySelector('#welcomeView').classList.remove('hidden');
    return;
  }
  if (action === 'open-project') {
    document.querySelector('#welcomeView').classList.add('hidden');
    notify('已打开最近项目');
    return;
  }
  if (action === 'toggle-bottom') {
    toolWindow.classList.toggle('collapsed');
    if (!toolWindow.classList.contains('collapsed')) renderTool(document.querySelector('.tool-tab.selected')?.dataset.tool || 'run');
    return;
  }
  if (action === 'run') {
    renderTool('run');
    document.querySelector('.run-health').classList.add('running');
    notify('BusinessCommonApplication 已启动');
    return;
  }
  if (action === 'debug') {
    renderTool('debug');
    notify('调试会话已启动');
    return;
  }
  if (action === 'stop') {
    const label = document.querySelector('.run-label');
    if (label) label.textContent = '已停止';
    document.querySelector('.run-health').classList.remove('running');
    notify('运行进程已停止');
    return;
  }
  if (action === 'collapse') {
    document.querySelector('#ideView').classList.toggle('project-hidden');
    return;
  }
  const messages = {
    'new-project': '新建项目入口已预留',
    'clone-project': 'Clone Repository 入口已预留',
    'branch-menu': '分支菜单已预留',
    'config-menu': '运行配置菜单已预留',
    'new-file': '新建文件入口已预留',
    'new-tab': 'Search Everywhere 已预留',
    split: '编辑器分屏入口已预留',
    search: 'Search Everywhere 已预留',
    settings: '设置页面已预留',
    more: '更多操作已预留',
    'right-tool': '右侧工具窗口已预留',
  };
  notify(messages[action] || '功能已预留');
}

document.addEventListener('click', (event) => {
  const close = event.target.closest('.editor-tab i');
  if (close) {
    event.stopPropagation();
    closeTab(close.closest('.editor-tab'));
    return;
  }
  const fileTarget = event.target.closest('[data-file]');
  if (fileTarget) {
    openFile(fileTarget.dataset.file);
    return;
  }
  const folder = event.target.closest('.folder-row');
  if (folder) {
    const disclosure = folder.querySelector('.disclosure');
    const opening = disclosure?.textContent.trim() === '›';
    if (disclosure) disclosure.textContent = opening ? '⌄' : '›';
    folder.classList.toggle('open', opening);
    return;
  }
  const toolTab = event.target.closest('.tool-tab');
  if (toolTab) {
    renderTool(toolTab.dataset.tool);
    return;
  }
  const activity = event.target.closest('.activity');
  if (activity) {
    document.querySelectorAll('.activity').forEach((item) => item.classList.toggle('active', item === activity));
    const panel = activity.dataset.panel;
    if (['run', 'terminal', 'git', 'problems'].includes(panel)) renderTool(panel);
    else if (panel === 'project') document.querySelector('#ideView').classList.toggle('project-hidden');
    else notify(`${panel} 工具窗口已预留`);
    return;
  }
  const actionTarget = event.target.closest('[data-action]');
  if (actionTarget) handleAction(actionTarget.dataset.action);
});

document.querySelectorAll('.welcome-nav-item').forEach((item) => item.addEventListener('click', () => {
  document.querySelectorAll('.welcome-nav-item').forEach((nav) => nav.classList.toggle('active', nav === item));
  if (item.textContent.trim() !== 'Projects') notify(`${item.textContent.trim()} 页面将在后续阶段接入`);
}));

document.querySelector('.project-search input').addEventListener('input', (event) => {
  const query = event.target.value.trim().toLowerCase();
  document.querySelectorAll('.recent-project').forEach((item) => {
    item.hidden = query && !item.textContent.toLowerCase().includes(query);
  });
});

function wireHorizontalResizer() {
  const handle = document.querySelector('#projectResizer');
  const pane = document.querySelector('#projectPane');
  handle.addEventListener('pointerdown', (event) => {
    event.preventDefault();
    const startX = event.clientX;
    const startWidth = pane.getBoundingClientRect().width;
    handle.setPointerCapture(event.pointerId);
    document.body.classList.add('resizing-x');
    const move = (moveEvent) => {
      const width = Math.min(520, Math.max(235, startWidth + moveEvent.clientX - startX));
      pane.style.width = `${width}px`;
      localStorage.setItem('lithe-project-width', String(width));
    };
    const up = () => {
      handle.removeEventListener('pointermove', move);
      document.body.classList.remove('resizing-x');
    };
    handle.addEventListener('pointermove', move);
    handle.addEventListener('pointerup', up, { once: true });
  });
}

function wireVerticalResizer() {
  const handle = document.querySelector('#toolResizer');
  handle.addEventListener('pointerdown', (event) => {
    event.preventDefault();
    toolWindow.classList.remove('collapsed');
    const startY = event.clientY;
    const startHeight = toolWindow.getBoundingClientRect().height;
    handle.setPointerCapture(event.pointerId);
    document.body.classList.add('resizing-y');
    const move = (moveEvent) => {
      const height = Math.min(520, Math.max(150, startHeight + startY - moveEvent.clientY));
      toolWindow.style.height = `${height}px`;
      localStorage.setItem('lithe-tool-height', String(height));
    };
    const up = () => {
      handle.removeEventListener('pointermove', move);
      document.body.classList.remove('resizing-y');
    };
    handle.addEventListener('pointermove', move);
    handle.addEventListener('pointerup', up, { once: true });
  });
}

document.addEventListener('keydown', (event) => {
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'p') {
    event.preventDefault();
    notify('Search Everywhere · 输入文件名');
  }
  if (event.key === 'Escape') document.querySelector('#welcomeView').classList.add('hidden');
});

const savedProjectWidth = Number(localStorage.getItem('lithe-project-width'));
if (savedProjectWidth) document.querySelector('#projectPane').style.width = `${savedProjectWidth}px`;
wireHorizontalResizer();
wireVerticalResizer();
openFile('BusinessCommonApplication.java', false);
