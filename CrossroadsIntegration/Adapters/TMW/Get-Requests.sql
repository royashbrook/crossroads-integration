;with source_rows as (
	select
		  [seq] = convert(int, j.[key])
		, r.*
	from openjson(@Source) j
	cross apply openjson(j.value) with (
		  order_number varchar(64)
		, source_status varchar(10)
		, progress_status varchar(40)
		, updated_date datetime2(3)
		, site_id nvarchar(255)
		, site_name nvarchar(max)
		, product_id nvarchar(255)
		, product_name nvarchar(max)
		, supplier_id nvarchar(255)
		, supplier_name nvarchar(max)
		, terminal_id nvarchar(255)
		, terminal_name nvarchar(max)
		, volume varchar(64)
		, window_start varchar(40)
		, window_end varchar(40)
		, delivery_eta varchar(40)
		, lift_depart varchar(40)
		, lift_status varchar(10)
		, drop_depart varchar(40)
		, drop_status varchar(10)
		, bol_number nvarchar(255)
		, bol_date varchar(40)
		, gross_volume varchar(64)
		, net_volume varchar(64)
		, tank_allocations nvarchar(max) as json
	) r
), positive_rows as (
	select *, [drop_volume] = sum(try_convert(float, volume)) over (partition by order_number, site_id, product_id)
	from source_rows
	where try_convert(float, nullif(volume, '')) > 0
), rows as (
	select * from positive_rows where drop_volume > 0.5
), totals as (
	select
		  s.order_number
		, [first_seq]      = coalesce(min(r.seq), min(s.seq))
		, [updated_date]   = max(s.updated_date)
		, [lifts_open]     = sum(case when r.seq is not null and coalesce(upper(trim(r.lift_status)), '') != 'DNE' then 1 else 0 end)
		, [drops_open]     = sum(case when r.seq is not null and coalesce(upper(trim(r.drop_status)), '') != 'DNE' then 1 else 0 end)
		, [drops_done]     = sum(case when upper(trim(r.drop_status)) = 'DNE' then 1 else 0 end)
		, [drop_actual]    = max(case when upper(trim(r.drop_status)) = 'DNE' then nullif(r.drop_depart, '') end)
		, [lift_actual]    = max(nullif(r.lift_depart, ''))
	from source_rows s
	left join rows r on r.seq = s.seq
	group by s.order_number
), missing as (
	select distinct r.order_number, v.position, v.field, v.completion
	from rows r
	cross apply (values
		  (1, 'site_id', 0, cast(r.site_id as nvarchar(max)))
		, (2, 'product_id', 0, cast(r.product_id as nvarchar(max)))
		, (3, 'supplier_id', 0, cast(r.supplier_id as nvarchar(max)))
		, (4, 'terminal_id', 0, cast(r.terminal_id as nvarchar(max)))
		, (5, 'volume', 0, cast(r.volume as nvarchar(max)))
		, (6, 'window_start', 0, cast(r.window_start as nvarchar(max)))
		, (7, 'window_end', 0, cast(r.window_end as nvarchar(max)))
		, (8, 'bol_number', 1, cast(r.bol_number as nvarchar(max)))
		, (9, 'bol_date', 1, cast(r.bol_date as nvarchar(max)))
		, (10, 'gross_volume', 1, cast(r.gross_volume as nvarchar(max)))
		, (11, 'net_volume', 1, cast(r.net_volume as nvarchar(max)))
	) v(position, field, completion, value)
	where nullif(trim(v.value), '') is null
), problems as (
	select
		  order_number
		, completion
		, [fields] = string_agg(cast(field as varchar(max)), ', ') within group (order by position)
	from missing
	group by order_number, completion
), states as (
	select
		  f.*
		, [latest_updated] = t.updated_date
		, [progress]       = case
			when upper(trim(f.source_status)) = 'CMP' and t.drops_open = 0 then 'complete'
			when t.drops_done > 0 then 'completed_drop'
			when t.lifts_open = 0 then 'driving_to_drop'
			else nullif(trim(f.progress_status), '')
		  end
		, [actual]         = case when t.drops_done > 0 then t.drop_actual when t.lifts_open = 0 then t.lift_actual end
		, [base_hold]      = case
			when p.fields is not null then 'missing ' + p.fields
			when convert(datetimeoffset, f.window_end) <= convert(datetimeoffset, f.window_start)
				then 'delivery window end must be after start'
		  end
		, [completion_hold] = case when c.fields is not null then 'completion missing ' + c.fields
			when exists (select 1 from rows r where r.order_number = f.order_number
				and (coalesce(try_convert(float, r.net_volume), 0) <= 0 or coalesce(try_convert(float, r.gross_volume), 0) <= 0
					or try_convert(datetimeoffset, r.bol_date) is null)) then 'completion requires positive volumes and a valid BOL date' end
	from totals t
	join source_rows f on f.seq = t.first_seq
	left join problems p on p.order_number = f.order_number and p.completion = 0
	left join problems c on c.order_number = f.order_number and c.completion = 1
), keys as (
	select
		  r.*
		, [site_key] = (select nullif(trim(site_id), '') as source_id, nullif(trim(site_name), '') as source_name for json path, without_array_wrapper)
		, [site_product_key] = (select nullif(trim(site_id), '') as source_id, nullif(trim(site_name), '') as source_name, nullif(trim(product_id), '') as product_source_id for json path, without_array_wrapper)
		, [product_key] = (select nullif(trim(product_id), '') as source_id, nullif(trim(product_name), '') as source_name for json path, without_array_wrapper)
		, [supplier_key] = (select nullif(trim(supplier_id), '') as source_id, nullif(trim(supplier_name), '') as source_name for json path, without_array_wrapper)
		, [terminal_key] = (select nullif(trim(terminal_id), '') as source_id, nullif(trim(terminal_name), '') as source_name for json path, without_array_wrapper)
	from rows r
), allocations as (
	select r.seq, a.tank_id, a.quantity
	from rows r
	cross apply openjson(r.tank_allocations) with (tank_id varchar(20), quantity float) a
	where a.quantity > 0
), drop_readiness as (
	select r.seq, [ready] = case
		when try_convert(float, r.net_volume) > 0 and try_convert(datetimeoffset, r.drop_depart) is not null
			and count(a.seq) > 0 and count(a.seq) = count(nullif(trim(a.tank_id), ''))
			and (count(a.seq) = 1 or abs(sum(a.quantity) - try_convert(float, r.net_volume)) < 0.000001)
		then 1 else 0 end
	from rows r
	left join allocations a on a.seq = r.seq
	group by r.seq, r.net_volume, r.drop_depart
), payloads as (
	select
		  s.*
		, [order_key] = (select s.order_number for json path, without_array_wrapper)
		, [window] = (select s.window_start as start, s.window_end as [end], 'UTC' as timezone for json path, without_array_wrapper, include_null_values)
		, [drops] = (
			select
				  [site]    = json_query(d.site_product_key)
				, [product] = json_query(d.product_key)
				, [volume]  = convert(int, case when abs(g.volume - round(g.volume, 0, 1)) = 0.5 and convert(bigint, round(g.volume, 0, 1)) % 2 = 0 then round(g.volume, 0, 1) else round(g.volume, 0) end)
				, [loads]   = json_query((
					select
						  [terminals] = json_query('[' + k.terminal_key + ']')
						, [products]  = json_query('[' + k.product_key + ']')
						, [suppliers] = json_query('[' + k.supplier_key + ']')
						, [price_types] = json_query('[]')
						, [contracts] = json_query('[]')
					from (
						select [first_seq] = min(seq), terminal_id, product_id, supplier_id
						from rows
						where order_number = s.order_number and site_id = d.site_id and product_id = d.product_id
						group by terminal_id, product_id, supplier_id
					) l
					join keys k on k.seq = l.first_seq
					order by concat(l.terminal_id, '|', l.product_id, '|', l.supplier_id)
					for json path
				  ))
			from (
				select [first_seq] = min(seq), site_id, product_id, [volume] = sum(convert(float, nullif(volume, '')))
				from rows where order_number = s.order_number
				group by site_id, product_id
			) g
			join keys d on d.seq = g.first_seq
			order by concat(g.site_id, '|', g.product_id)
			for json path, include_null_values
		  )
	from states s
)
select
	  [order_number] = p.order_number
	, [updated_date] = convert(varchar(23), p.latest_updated, 126)
	, [progress]     = case when p.base_hold is null and upper(trim(p.source_status)) != 'CAN' then p.progress end
	, [hold]         = case when exists (select 1 from rows where order_number = p.order_number) then coalesce(p.base_hold, case when upper(trim(p.source_status)) != 'CAN' then
		case when p.progress is null then 'unmapped status ' + p.source_status when p.progress = 'complete' then p.completion_hold end end)
	  end
	, [requests]     = json_query(coalesce((
		select
			  q.kind
			, q.path
			, [message_key] = concat(q.kind, case when q.kind in ('save_bol', 'save_drop') then '|' + q.sortkey end)
			, [payload_json] = q.payload
		from (
			select 10 as position, '' as sortkey, 'create' as kind, '/v1/order/create' as path, (
				select p.order_number as origin_order_number, json_query(p.[window]) as delivery_window, json_query(p.drops) as drops, 'gallons' as units, cast(1 as bit) as created_by_hauler
				for json path, without_array_wrapper
			) as payload
			where p.base_hold is null and upper(trim(p.source_status)) != 'CAN'
			union all
			select 20, '', 'update', '/v1/order/update', (
				select json_query(p.order_key) as [order], json_query(p.[window]) as delivery_window, json_query(p.drops) as drops
				for json path, without_array_wrapper
			)
			where p.base_hold is null and upper(trim(p.source_status)) != 'CAN'
			union all
			select 30, concat(trim(b.bol_number), '|', trim(b.terminal_id)), 'save_bol', '/v1/order/save_bol', (
				select
					  [order]    = json_query(p.order_key)
					, [bol_number] = trim(b.bol_number)
					, [terminal] = json_query(b.terminal_key)
					, [bol_date] = b.bol_date
					, [details]  = json_query((
						select
							  [site]         = json_query(k.site_product_key)
							, [supplier]     = json_query(k.supplier_key)
							, [product]      = json_query(k.product_key)
							, [net_volume]   = coalesce(try_convert(decimal(38, 16), nullif(k.net_volume, '')), convert(decimal(38, 16), convert(float, nullif(k.net_volume, ''))))
							, [gross_volume] = coalesce(try_convert(decimal(38, 16), nullif(k.gross_volume, '')), convert(decimal(38, 16), convert(float, nullif(k.gross_volume, ''))))
						from keys k
						where k.order_number = p.order_number and k.bol_number = b.bol_number and k.terminal_id = b.terminal_id
						order by k.seq
						for json path, include_null_values
					  ))
				for json path, without_array_wrapper, include_null_values
			)
			from (select min(seq) as first_seq from rows where order_number = p.order_number group by bol_number, terminal_id) g
			join keys b on b.seq = g.first_seq
			where p.base_hold is null and p.completion_hold is null and p.progress = 'complete' and upper(trim(p.source_status)) != 'CAN'
			union all
			select 40, trim(s.site_id), 'save_drop', '/v1/order/save_drop', (
				select
					  [order]   = json_query(p.order_key)
					, [site]    = json_query(s.site_key)
					, [mode]    = 'replace'
					, [details] = json_query((
						select
							  [product]        = json_query(k.product_key)
							, [quantity]       = convert(decimal(38, 16), case when (select count(*) from allocations where seq = k.seq) = 1 then convert(float, k.net_volume) else a.quantity end)
							, [post_drop_time] = k.drop_depart
							, [tank]           = json_query((select trim(k.site_id) as source_id, a.tank_id for json path, without_array_wrapper))
						from keys k
						join allocations a on a.seq = k.seq
						where k.order_number = p.order_number and k.site_id = s.site_id
						order by k.seq, a.tank_id
						for json path, include_null_values
					  ))
				for json path, without_array_wrapper
			)
			from (select min(seq) as first_seq from rows where order_number = p.order_number group by site_id) g
			join keys s on s.seq = g.first_seq
			where p.base_hold is null and p.progress = 'complete' and upper(trim(p.source_status)) != 'CAN'
				and not exists (select 1 from rows r join drop_readiness dr on dr.seq = r.seq where r.order_number = p.order_number and r.site_id = s.site_id and dr.ready = 0)
			union all
			select 90, '', 'status', '/v1/order/update_status', case when p.progress = 'complete' then (
				select json_query(p.order_key) as [order], p.progress as progress_status, p.actual
				for json path, without_array_wrapper, include_null_values
			) else json_modify((
				select
					  [order]         = json_query(p.order_key)
					, [progress_status] = p.progress
					, [delivery_eta]  = p.delivery_eta
					, [actual]        = p.actual
					, [site]          = json_query(case when p.progress in ('driving_to_drop', 'arrived_at_drop', 'dropping', 'completed_drop') then coalesce(d.site_key, f.site_key) end)
					, [location]      = json_query(case when p.progress not in ('driving_to_drop', 'arrived_at_drop', 'dropping', 'completed_drop') then f.terminal_key end)
				for json path, without_array_wrapper, include_null_values
			), case when p.progress in ('driving_to_drop', 'arrived_at_drop', 'dropping', 'completed_drop') then '$.location' else '$.site' end, null) end
			from keys f
			outer apply (select top (1) k.site_key from keys k where k.order_number = p.order_number and upper(trim(k.drop_status)) = 'DNE' order by k.drop_depart desc, k.seq) d
			where f.seq = p.seq and p.base_hold is null and p.progress is not null
				and try_convert(datetimeoffset, p.actual) is not null
				and (p.progress != 'complete' or p.completion_hold is null) and upper(trim(p.source_status)) != 'CAN'
				and (p.progress != 'complete' or not exists (select 1 from rows r join drop_readiness dr on dr.seq = r.seq where r.order_number = p.order_number and dr.ready = 0))
			union all
			select 99, '', 'cancel', '/v1/order/cancel', (
				select json_query(p.order_key) as [order], 'CANCELLED IN TMS' as reason_code
				for json path, without_array_wrapper
			)
			where upper(trim(p.source_status)) = 'CAN'
		) q
		where q.kind = 'cancel' or exists (select 1 from rows where order_number = p.order_number)
		order by q.position, q.sortkey
		for json path
	  ), '[]'))
from payloads p
order by p.order_number
for json path, include_null_values
