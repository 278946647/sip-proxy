import { Select, Tag, Typography } from "antd";
import type { SelectProps } from "antd";
import type { SocksProfile } from "../types";

function maskAddress(display: string, host: string, port: number): string {
  if (display && display.includes("@")) {
    const at = display.indexOf("@");
    const cred = display.slice(0, at);
    const rest = display.slice(at + 1);
    if (cred.length > 4) {
      return `${cred.slice(0, 4)}…@${rest}`;
    }
  }
  return `${host}:${port}`;
}

export function SocksProfileOptionRow({ profile }: { profile: SocksProfile }) {
  const addr = maskAddress(profile.addressDisplay, profile.host, profile.port);
  return (
    <div style={{ padding: "4px 0", lineHeight: 1.45 }}>
      <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
        <Typography.Text strong style={{ fontSize: 13 }}>
          {profile.name}
        </Typography.Text>
        <Tag color={profile.isHealthy ? "success" : "error"} style={{ margin: 0 }}>
          {profile.isHealthy ? "在线" : "离线"}
        </Tag>
        {profile.lineBindingCount > 0 ? (
          <Tag color="warning" style={{ margin: 0 }}>
            已绑定 {profile.lineBindingCount}
          </Tag>
        ) : null}
      </div>
      <Typography.Text type="secondary" style={{ fontSize: 12 }}>
        {addr}
        {profile.country ? ` · ${profile.country}` : ""}
        {profile.remark ? ` · ${profile.remark}` : ""}
      </Typography.Text>
    </div>
  );
}

type SocksProfileSelectProps = Omit<SelectProps, "options"> & {
  profiles: SocksProfile[];
};

export function SocksProfileSelect({ profiles, ...rest }: SocksProfileSelectProps) {
  const options = profiles.map((p) => ({
    value: p.id,
    label: `${p.name} (${p.host}:${p.port})`,
    profile: p,
    searchText: [p.name, p.host, String(p.port), p.country, p.remark, p.addressDisplay]
      .filter(Boolean)
      .join(" ")
      .toLowerCase(),
  }));

  return (
    <Select
      allowClear
      showSearch
      placeholder="节点本地网络出局"
      popupMatchSelectWidth={520}
      optionLabelProp="label"
      filterOption={(input, option) =>
        String(option?.searchText ?? "").includes(input.trim().toLowerCase())
      }
      options={options}
      optionRender={(opt) => <SocksProfileOptionRow profile={opt.data.profile as SocksProfile} />}
      {...rest}
    />
  );
}
