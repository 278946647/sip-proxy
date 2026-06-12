import { Button, Input, Space, Typography, message } from "antd";
import { CopyOutlined } from "@ant-design/icons";
import { copyToClipboard } from "../utils/clipboard";

type Props = {
  value: string;
  loading?: boolean;
  onRefresh?: () => void;
  rows?: number;
};

/** Read-only line code display; selection allowed, editing disabled. */
export function LineCodeField({ value, loading, onRefresh, rows = 4 }: Props) {
  const display = value.trim() || "（暂无线路码，请点击刷新或复制获取）";

  const handleCopy = async () => {
    try {
      if (!value.trim()) {
        message.warning("请先刷新线路码");
        onRefresh?.();
        return;
      }
      await copyToClipboard(value);
      message.success("线路码已复制");
    } catch (e) {
      message.error(String(e));
    }
  };

  return (
    <div>
      <Input.TextArea
        readOnly
        value={display}
        rows={rows}
        style={{
          fontFamily: "monospace",
          marginBottom: 8,
          backgroundColor: "#f5f5f5",
          color: "#334155",
          cursor: "default",
          userSelect: "text",
        }}
        onChange={() => undefined}
      />
      <Typography.Text type="secondary" style={{ fontSize: 12, display: "block", marginBottom: 8 }}>
        只读展示，可选中复制，不可编辑
      </Typography.Text>
      <Space>
        <Button
          type="primary"
          icon={<CopyOutlined />}
          loading={loading}
          onClick={() => void handleCopy().catch(() => undefined)}
        >
          复制线路码
        </Button>
        {onRefresh ? (
          <Button loading={loading} onClick={onRefresh}>
            刷新线路码
          </Button>
        ) : null}
      </Space>
    </div>
  );
}
