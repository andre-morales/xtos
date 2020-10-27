[BITS 16]
[CPU 8086]

; -- [0x500 - 0x800] Stack
; -- [0x800 - 0xA00] Loaded stage 1.0 [ MBR ]
; -- [0xA00 - 0x1400] Loaded stage 1.5
; -- [0x1400 - 0x1500] Unitialiazed varible storage
; -- [0x1500 - 0x1600] Partition array
; -- [0x2000] Generic stuff buffer
%include "ext/enter_leave8086_h.asm"
%include "ext/stdconio_h.asm"
%include "core_h.asm"

db 'Xt' ; Signature

Start:
	; Copy CS [Segment 0xA0] into other segments
	push cs 
 pop ds
	push cs 
 pop es
		
	; Save drive number
	mov [drive], dl
	
	; Save bytes per sector.
	mov [drive.CHS_bytesPerSector], di
	
	mov sp, 0x800 ; Readjust stack behind us and the MBR.	
	sti           ; Reenable interrupt
	
	mov ax, 0xAAAA
	mov bx, 0xBBBB
	mov cx, 0xCCCC
	mov dx, 0xDDDD
	mov bp, 0xEEEE
	mov di, 0xFFFF
	
	Print(Constants.string1)
	call getCurrentVideoMode
	call getDriveGeometry
	
	Print(Constants.string2)
	mov ax, 0 
	mov es, ax 
 mov di, 0x1500 ; Set up ES:DI to [0000:1200]
	push ax    
 push ax         ; LBA 0. (MBR)
	mov ax, 1  
 push ax         ; In root mbr.
	call getPartitionMap
	
	Print(Constants.string3)
	sub di, 0x1500
	mov ax, di
	mov cl, 9
	div cl
	mov [partitionMapSize], al
	
	Print(Constants.string4)
	Pause()
		
	mov word [cursor], 0
	MainMenu:
		call clearScreen
		
	MenuSelect:
		call DrawMenu
			
		Getch()
		cmp ah, 48h 
 je .upKey
		cmp ah, 50h 
 je .downKey
	
		cmp ah, 1Ch
		;je EnterPartition
		jmp MainMenu
		
		.upKey:
		mov ax, [cursor]
		test ax, ax 
 jnz .L3
		
		mov al, [partitionMapSize]
		
		.L3:
		dec ax
		div byte [partitionMapSize]
		mov [cursor], ah
		jmp MenuSelect
		
		.downKey:
		mov ax, [cursor]
		inc ax
		div byte [partitionMapSize]
		mov [cursor], ah
		jmp MenuSelect

; void (int32 LBA)
readSector: 
	push bp
	mov bp, sp
	sub sp, 4
	
	push es 
 push di
	push si
	push cx 
 push dx
	
	Print(Constants.string5)
	PrintHexNum [bp + 6]
	PrintHexNum [bp + 4]
		
	cmp byte [drive.LBA_support], 2
	jmp .LBAtoCHS ; LBA not supported. Try CHS translation.
	
	; -- Reading as LBA --
	mov ax, [bp + 4] 
 mov [lbaDAPS.lba + 0], ax
	mov ax, [bp + 6] 
 mov [lbaDAPS.lba + 2], ax
	mov dl, [drive]
	mov si, lbaDAPS
	mov ah, 0x42 
 int 13h ; Extended read
	xor ax, ax
	jmp .End
	
	; -- Reading as CHS (Convert LBA to CHS) --
	.LBAtoCHS: 		
		; Calculate cylinder to BP - 2
		mov dx, [bp + 6] 
 mov ax, [bp + 4]             ; Get LBA
		div word [drive.CHS_sectorsTimesHeads]          ; LBA / (HPC * SPT) | DX:AX / (HPC * SPT)
		mov [bp - 2], ax                                ; Save Cylinders
		
		; Print cylinder
		Print(Constants.string6)
		call printHexNumber
		
		cmp ax, [drive.CHS_cylinders] 
 jle .CHSRead ; Is cylinder number sabe?
		
		mov ax, 1 
 jmp .End ; Error code 1. Cylinder too big.
		
		.CHSRead:
		; Calculate sector to BP - 3
		mov dx, [bp + 6] 
 mov ax, [bp + 4]              ; Get LBA
		xor ch, ch 
 mov cl, [drive.CHS_sectorsPerTrack] 
		div cx                                           ; LBA % SPT + 1 | LBA % CX + 1
		inc dx
		mov [bp - 3], dl
		
		; Calculate head to BP - 4
		div byte [drive.CHS_headsPerCylinder]            ; (LBA / SPT) % HPC # (LBA / CX) % HPC
		mov [bp - 4], ah
		

		
		Print(Constants.string7)
		xor ah, ah
		mov al, [bp - 4]
		call printHexNumber
		
		Print(Constants.string8)
		xor ah, ah
		mov al, [bp - 3]
		call printHexNumber
		
		; Cylinder
		mov ax, [bp - 2]
		mov cl, 8 
 rol ax, cl
		mov cl, 6 
 shl al, cl 
		mov cx, ax
		
		or cl, [bp - 3]  ; Sector
		mov dh, [bp - 4] ; Head
		
		xor bx, bx 
 mov es, bx
		mov bx, 0x2000
		mov dl, [drive]
		mov al, 1
		mov ah, 0x02 
 int 13h ; CHS read
		
		xor ax, ax
	
	
	.End:
	pop dx 
 pop cx
	pop si
	pop di 
 pop es
	mov sp, bp
	pop bp
	
	pop bx    ; Get return address from stack
	add sp, 4 ; Remove argument from stack
jmp bx 

; void (ES:DI pntrToPartitionArray, int32 LBA, int16 inMBR)
getPartitionMap: 
	; + 6 (32) Address of the MBR we are going to load.
	; + 4 (16) If we are at the root MBR or exploring the EBR daisy chain
	; + 2 (16) Return Address
	; + 0 (16) Older BP.

	push bp
	mov bp, sp
	push ds ; Save DS
	push bx ; save BX
	push cx ; Save CX
	push si ; Save SI

	; Push to stack the address of the MBR, and read the MBR to the common buffer at 0x2000.
	push word [bp + 8] 
 push word [bp + 6] 
	call readSector
	test ax, ax 
 je .GetPartitionEntries ; Did it read properly?
	
	; AX is not 0. It failed somehow.
	Print(Constants.string9)
	cmp ax, 1 
 je .OutOfRangeCHS
	Print(Constants.string10)
	jmp .ErrorOut
	
	.OutOfRangeCHS:
	Print(Constants.string11)
	
	.ErrorOut:
	Print(Constants.string12)
	jmp .End
	
	.GetPartitionEntries:
	; Set DS:SI to point to the common buffer + end of the partion table.
	mov ax, 0 
 mov ds, ax
	mov si, 0x2000 + 0x1BE + 48
	
	mov cx, 4
	mov dx, 0
	.FindPart:
		mov al, [ds:si + 4]   ; Get partition type.
		cmp al, 0 
 je .next0 ; No partition, look next slot.
		
		inc dx
		push ax        ; Save partition type.
		
		; Add current MBR address with starting LBA address.
		; Save starting LBA (low)
		mov ax, [ds:si + 8]
		add ax, [ss:bp + 6]
		push ax
		
		; Save starting LBA (high)
		mov ax, [ds:si + 10]
		adc ax, [ss:bp + 8]
		push ax	
		
		; Save partition size
		push word [ds:si + 12]
		push word [ds:si + 14]
		
		.next0:
		sub si, 16
	loop .FindPart
	
	mov ds, [bp - 2] ; Get DS back
	mov cx, dx
	.GetPart:
		mov bx, sp
		mov dl, [ss:bx + 8] ; Get partition type
		add sp, 10  ; Remove partition entry from stack.
		cmp dl, 05h ; Is it an extended partition?
		jne .store  ; It's not, just store it.
		
		cmp byte [bp + 4], 0 ; Are we already exploring the EBR daisy chain?
		je .ebr              ; Yes, don't store yet another EBR entry, go straight to the recursion.
		
		.store:
		mov al, dl          
 stosb ; Store partition type to ES:DI
		mov ax, [ss:bx + 6] 
 stosw ; Store low part of LBA address
		mov ax, [ss:bx + 4] 
 stosw ; Store high part of LBA address
		mov ax, [ss:bx + 2] 
 stosw ; Store low part of partition size
		mov ax, [ss:bx + 0] 
 stosw ; Store high part of partition size
		
		cmp dl, 05h 
 jne .next1 ; Is it a extended partition type?
		
		.ebr:
		; It is. Call ourselves with its LBA address...	
		; Push LBA address and push nesting depth
		push word [ss:bx + 4] ; High part
		push word [ss:bx + 6] ; Low part
		mov dx, 0 
 push dx ; Explore the EBR daisy chain
		call getPartitionMap
		.next1:
	loop .GetPart
	
	.End:
	pop si
	pop cx
	pop bx
	
	mov sp, bp
	pop bp
	pop dx    ; Get return address
	add sp, 6 ; Remove parameters at the stack.
jmp dx 

getCurrentVideoMode: 
	mov ah, 0Fh 
 int 10h
	push ax
	Print(Constants.string13)
	xor ah, ah
	call printHexNumber
	
	Print(Constants.string14)
	pop ax
	mov al, ah
	xor ah, ah
	call printDecNumber	
ret 

getDriveGeometry:
	Print(Constants.string15)
	Print(Constants.string16)
	
	call getDriveCHSProperties
	
	; -- Print CHS properties --
	Print(Constants.string17)
	PrintDecNum [drive.CHS_bytesPerSector]
	
	xor ah, ah
	Print(Constants.string18)
	mov al, [drive.CHS_sectorsPerTrack]
	call printDecNumber

	Print(Constants.string19)
	mov al, [drive.CHS_headsPerCylinder]
	call printDecNumber
	
	Print(Constants.string20)
	PrintDecNum [drive.CHS_sectorsTimesHeads]
	
	Print(Constants.string21)
	PrintDecNum [drive.CHS_cylinders]
	
	Print(Constants.string22)
	call getDriveLBAProperties
	
	mov al, [drive.LBA_support]
	cmp al, 2 
 je .printLBAProps
	cmp al, 1 
 je .noDriveLBA
	
	Print(Constants.string23)
	jmp .End
	
	.noDriveLBA:
	Print(Constants.string24)
	jmp .End
	
	.printLBAProps:
	Print(Constants.string25)
	PrintDecNum [drive.LBA_bytesPerSector]
	
	.End:
ret

DrawMenu: 
	push bp
	mov bp, sp
	sub sp, 4
	mov word [bp - 2], 0
	mov [bp - 4], es
	
	mov bx, 00_00h
	mov ax, 25_17h
	call drawSquare
	
	mov dx, 01_01h
	call setCursor
	
	Print(Constants.string26)
	
	mov ah, 0 
 mov al, [drive]
	call printHexNumber
	
	inc dh 
 call setCursor
	
	mov dx, 03_03h
	
	xor di, di 
 mov es, di
	mov di, 0x1500
	mov cl, 0
	.drawPartition:
		call setCursor
		mov byte [bp - 2], 0x6F
		
		cmp cl, [cursor] 
 jne .printSpace
		mov byte [bp - 2], 0x1F
		
		.printSpace:
		cmp byte [bp - 1], 0 ; Listing primary partitions?
		je .printTypeName
		
		PrintColor Constants.string27, [bp - 2]
		
		.printTypeName:		
		mov al, [es:di] ; Partition type
		cmp al, 05h 
 jne .printTypeName2
		mov byte [bp - 1], 1
		
		.printTypeName2:
		call getPartitionTypeName
		mov al, [bp - 2] 
 call printColorStr
				
		PrintColor Constants.string28, [bp - 2]	
		
		; Save a bunch of registers
		push cx 
 push dx
		push es 
 push di
		
		; Push size of partition to stack
		push word [es:di + 5]
		push word [es:di + 7]
		
		; Set ES to DS
		push ds 
 pop es
		
		; Zero out string
		mov si, partitionSizeStrBuff
		mov di, si
		mov al, 0
		mov cx, 6
		rep stosb
		
		pop dx 
 pop ax ; Get partition size from stack 
		mov cx, 2048 
 div cx
		mov di, si
		call decNumToStr
		
		mov al, [bp - 2]
		call printColorStr
		
		; Get the bunch of registers back
		pop di 
 pop es
		pop dx 
 pop cx
		
		PrintColor Constants.string29, [bp - 2]
		
		add di, 9
		inc dh
		inc cx
	cmp cl, [partitionMapSize] 
 jne .drawPartition

	mov es, [bp - 4]
	mov sp, bp
	pop bp
ret 
	
DBG_ClearStack: 
	pop bx     ; Get return address
	mov ax, bp ; Save BP in other register
	mov bp, sp
	
	mov cx, 64
	mov dx, 0xFFFF
	.store:
		push dx
	loop .store
	
	mov sp, bp
	mov bp, ax
jmp bx 
	
getDriveLBAProperties: 
	mov dl, [drive]
	
	mov bx, 0x55AA
	mov ah, 41h 
 int 13h ; LBA available?
	
	jc .NoDriveLBA
	
	cmp bx, 0xAA55 
 jne .NoBiosLBA
	
	push ds                ; Save DS
	mov ax, 0 
 mov ds, ax ; Set DS to 0
	mov si, 0x2000         ; Load table to [0x0000:2000h]
	mov ah, 48h 
 int 13h  ; Query extended drive parameters.
		
	mov ax, [0x2000 + 0x18]                  ; Get bytes/sector
	pop ds                                   ; Get DS back
	mov byte [drive.LBA_support], 2          ; LBA is supported
	mov word [drive.LBA_bytesPerSector], ax  ; Save bytes/sector
	jmp .End
	
	.NoDriveLBA:
	mov byte [drive.LBA_support], 1
	jmp .End
	
	.NoBiosLBA:
	mov byte [drive.LBA_support], 0
	
	.End:
ret 

getDriveCHSProperties: 
	mov dl, [drive]
	mov ah, 08h 
 int 13h ; Query drive geometry
	
	inc dh
	mov [drive.CHS_headsPerCylinder], dh
	
	mov ax, cx
	and al, 0b00111111
	mov [drive.CHS_sectorsPerTrack], al
	
	mul dh
	mov [drive.CHS_sectorsTimesHeads], ax
	
	mov ax, cx ; LLLLLLLL|HHxxxxxx
	
	mov cl, 8
	rol ax, cl ; HHxxxxxx|LLLLLLLL
	
	mov cl, 6
	shr ah, cl ; ------HH|LLLLLLLL
	inc ax
	mov [drive.CHS_cylinders], ax
ret 
	
getPartitionTypeName:
	push bx
	
	mov bl, al
	xor bh, bh
	mov bl, [PartitionTypeNamePtrIndexArr + bx]	
	add bx, bx
	mov si, [PartitionTypeNamePtrArr + bx]
	
	pop bx
ret
	
drawSquare: 
	push bp
	mov bp, sp
	push ax
	
	xor ch, ch
	
	; Top box row
	mov dx, bx
	call setCursor
	
	Putch(0xC9)
	Putnch 0xCD, [bp - 1]
	Putch(0xBB)
	
	; Left box column
	mov dx, bx	
	mov al, 0xBA
	
	mov cl, [bp - 2]
	.leftC:
		inc dh
		call setCursor	
		call putch
	loop .leftC
	
	inc dh
	call setCursor	
	
	; Bottom box row
	Putch(0xC8)
	Putnch 0xCD, [bp - 1]
	Putch(0xBC)
	
	; Right box row
	mov dx, bx
	add dl, [bp - 1]
	inc dl
	mov al, 0xBA
	mov cl, [bp - 2]
	.rightC:
		inc dh
		call setCursor	
		call putch
	loop .rightC	
	
	mov sp, bp
	pop bp
ret 
		
%include 'ext/stdconio.asm'

lbaDAPS:  db 16       ; Size
	      db 0x00     ; Always 0
	      dw 0x0001   ; Sectors to read
		  dw 0x2000   ; Destination buffer
	      dw 0x0000   ; Destination segment
	.lba: dd 0x000000 ; Lower LBA
	      dd 0x000000 ; Upper LBA

PartitionTypeNamePtrIndexArr:
	db 0, 1, 1, 1, 1, 5, 2, 1
	db 1, 1, 1, 3, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 4, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1

PartitionTypeNamePtrArr:
	dw Constants.string30
	dw Constants.string31
	dw Constants.string32
	dw Constants.string33
	dw Constants.string34
	dw Constants.string35

Constants:
	.string1: db "", 0Dh, "", 0Dh, 0Ah, "--- Xt Generic Boot Manager ---", 0Dh, 0Ah, "", 0
	.string2: db "", 0Dh, 0Ah, "Reading partition map...", 0
	.string3: db "", 0Dh, 0Ah, "Partition map read.", 0
	.string4: db "", 0Dh, 0Ah, "Press any key to enter boot select...", 0Dh, 0Ah, "", 0
	.string5: db "", 0Dh, 0Ah, "Reading sector: 0x", 0
	.string6: db " C: 0x", 0
	.string7: db " H: 0x", 0
	.string8: db " S: 0x", 0
	.string9: db "", 0Dh, 0Ah, "Sector read failed. The error was:", 0Dh, 0Ah, " ", 0
	.string10: db "Unknown", 0
	.string11: db "CHS (Cylinder) address out of range", 0
	.string12: db ".", 0Dh, 0Ah, "Ignoring the partitions at this sector.", 0
	.string13: db "", 0Dh, 0Ah, "Current video mode: 0x", 0
	.string14: db "", 0Dh, 0Ah, "Columns: ", 0
	.string15: db "", 0Dh, 0Ah, "Figuring out drive properties...", 0Dh, 0Ah, "", 0
	.string16: db "", 0Dh, 0Ah, "[ Drive geometry as CHS (AH = 02h) ]", 0
	.string17: db "", 0Dh, 0Ah, " Bytes per Sector: ", 0
	.string18: db "", 0Dh, 0Ah, " Sectors per Track: ", 0
	.string19: db "", 0Dh, 0Ah, " Heads Per Cylinder: ", 0
	.string20: db "", 0Dh, 0Ah, " HPC * SPT: ", 0
	.string21: db "", 0Dh, 0Ah, " Cylinders: ", 0
	.string22: db "", 0Dh, 0Ah, "[ Drive geometry as LBA (AH = 48h) ]", 0
	.string23: db "", 0Dh, 0Ah, " Error: BIOS doesn't support LBA.", 0
	.string24: db "", 0Dh, 0Ah, " Error: Drive doesn't support LBA.", 0
	.string25: db "", 0Dh, 0Ah, " Bytes per Sector: ", 0
	.string26: db "Partitions on drive 0x", 0
	.string27: db " ", 0
	.string28: db " (", 0
	.string29: db " MiB)", 0
	.string30: db "Empty", 0
	.string31: db "Unknown", 0
	.string32: db "FAT16B", 0
	.string33: db "FAT32", 0
	.string34: db "Linux", 0
	.string35: db "Extended Partition", 0

times 5*512-($-$$) db 0x90 ; Fill rest of stage 1.5 with no-ops. (For alignment.)

; -- Variable space --
drive: db 0
	.CHS_bytesPerSector:    dw 0
	.CHS_sectorsPerTrack:   db 0
	.CHS_headsPerCylinder:  db 0
	.CHS_sectorsTimesHeads: dw 0
	.CHS_cylinders:         dw 0	
	.LBA_support:           db 0
	.LBA_bytesPerSector:    dw 0
	.logicalBytesPerSector: dw 0

cursor: dw 0
partitionMapSize: db 0
partitionSizeStrBuff: times 6 db 0