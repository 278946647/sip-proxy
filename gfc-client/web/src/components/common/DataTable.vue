<script setup lang="ts">
import { textValue } from '@/utils/data'

defineProps<{
  columns: Array<{ key: string; title: string }>
  rows: Array<Record<string, unknown>>
  emptyText?: string
}>()
</script>

<template>
  <div class="table-wrap">
    <table v-if="rows.length">
      <thead>
        <tr>
          <th v-for="column in columns" :key="column.key">{{ column.title }}</th>
          <th v-if="$slots.actions">操作</th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="(row, index) in rows" :key="String(row.id || row.name || index)">
          <td v-for="column in columns" :key="column.key">
            <slot :name="`cell-${column.key}`" :row="row" :value="row[column.key]">
              {{ textValue(row[column.key]) }}
            </slot>
          </td>
          <td v-if="$slots.actions">
            <slot name="actions" :row="row" :index="index" />
          </td>
        </tr>
      </tbody>
    </table>
    <div v-else class="empty">{{ emptyText || '暂无数据' }}</div>
  </div>
</template>

<style scoped>
.table-wrap {
  overflow: auto;
  background: var(--panel);
  border: 1px solid var(--border);
  border-radius: 4px;
}

table {
  width: 100%;
  border-collapse: collapse;
}

th,
td {
  padding: 9px 10px;
  text-align: left;
  border-bottom: 1px solid var(--border);
  white-space: nowrap;
}

th {
  background: #f8fafc;
  color: #334155;
  font-size: 12px;
  font-weight: 600;
}

.empty {
  padding: 18px;
  color: var(--muted);
  text-align: center;
}
</style>
