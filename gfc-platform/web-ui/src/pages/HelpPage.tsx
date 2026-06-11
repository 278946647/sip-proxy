import { Card, Typography } from "antd";

export function HelpPage() {
  return (
    <div>
      <Typography.Title level={4}>使用说明</Typography.Title>
      <Card>
        <Typography.Paragraph>
          <strong>1. 转发节点上线</strong>
          <br />
          在转发节点运行 <code>run_agent.py</code>，使用 bootstrap token 激活；控制台「健康检查」可查看在线状态。
        </Typography.Paragraph>
        <Typography.Paragraph>
          <strong>2. 配置 SOCKS 代理</strong>
          <br />
          在「代理配置」添加远端 SOCKS；用于线路出站原生 IP。
        </Typography.Paragraph>
        <Typography.Paragraph>
          <strong>3. 创建客户线路</strong>
          <br />
          在「线路管理」绑定节点、源 IP 段（VyOS 汇聚后可见的客户源地址）、SOCKS；保存后节点约 10 秒内拉取配置。
        </Typography.Paragraph>
        <Typography.Paragraph>
          <strong>4. 数据面（转发）</strong>
          <br />
          VyOS 将客户流量送至转发节点；节点按源 IP 最长前缀匹配，经 TPROXY + sing-box 转发至对应 SOCKS。
        </Typography.Paragraph>
        <Typography.Paragraph type="secondary">
          自动同步间隔由 NodeAgent <code>--poll-seconds</code> 控制（默认 10 秒）。
          运维与故障排查详见仓库 <code>docs/OPS.md</code>（日志保留、排查命令、gfc-logs）。
        </Typography.Paragraph>
      </Card>
    </div>
  );
}
