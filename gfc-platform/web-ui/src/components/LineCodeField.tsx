import { Button, Input, message } from "antd";
import { CopyOutlined } from "@ant-design/icons";
import { copyToClipboard } from "../utils/clipboard";

type Props = {
  value: string;
  loading?: boolean;
  rows?: number;
};

export function LineCodeField({ value, loading, rows = 4 }: Props) {
  const display = value.trim() || "暂无线路码";

  const handleCopy = async () => {
    try {
      if (!value.trim()) {
        message.warning("暂无线路码");
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
      <Button
        type="primary"
        icon={<CopyOutlined />}
        loading={loading}
        onClick={() => void handleCopy().catch(() => undefined)}
      >
        复制线路码
      </Button>
    </div>
  );
}
